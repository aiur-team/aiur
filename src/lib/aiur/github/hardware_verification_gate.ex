defmodule Aiur.GitHub.HardwareVerificationGate do
  @moduledoc "Posts the CI blind-spot notice when hardware work reaches human review."

  alias Aiur.HardwareVerification
  alias Aiur.GitHub.{Comments, Config, Errors, PullRequests, StatePolicy, Transport}

  @notice_marker "<!-- aiur:hardware-verification-required -->"
  @timeline_page_limit 4
  @timeline_response_limit 65_536

  @doc "Requires a human-merger-authored sign-off label event before terminalization."
  @spec verify_operator_signoff(map(), map(), String.t()) :: :ok | {:error, term()}
  def verify_operator_signoff(context, issue_body, state_name) do
    if StatePolicy.terminal_state_name?(state_name) and
         HardwareVerification.signoff_required?(issue_body, context.prefix) do
      with :ok <- HardwareVerification.verify_terminal_transition(issue_body, state_name, context.prefix),
           {:ok, events} <- fetch_timeline_events(context),
           {:ok, actor} <- latest_signoff_actor(events, HardwareVerification.verified_label(context.prefix)),
           true <- operator_authorized?(actor, context) do
        :ok
      else
        false -> {:error, {:operator_signoff_event_required, :untrusted_actor}}
        {:error, _reason} = error -> error
        _ -> {:error, {:operator_signoff_event_required, :invalid_operator_authorizer}}
      end
    else
      :ok
    end
  end

  @spec flag_ci_blind_spot(map(), map(), String.t()) :: :ok | {:error, term()}
  def flag_ci_blind_spot(context, issue_body, state_name) do
    if StatePolicy.human_review_target_state?(state_name) and HardwareVerification.signoff_required?(issue_body, context.prefix) do
      with {:ok, %{"number" => pr_number}} when is_integer(pr_number) <-
             PullRequests.fetch_open_pull_request_for_branch(context.issue_number,
               request_fun: context.request_fun,
               token: context.token
             ),
           {:ok, comments} <- Comments.fetch_issue_comments(pr_number, request_fun: context.request_fun, token: context.token),
           :ok <- maybe_post_notice(pr_number, comments, context) do
        :ok
      else
        {:ok, nil} -> :ok
        {:ok, _unexpected_pr} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp maybe_post_notice(pr_number, comments, context) when is_list(comments) do
    if Enum.any?(comments, &notice_comment?/1), do: :ok, else: post_notice(pr_number, context)
  end

  defp maybe_post_notice(pr_number, _comments, context), do: post_notice(pr_number, context)

  defp post_notice(pr_number, context) do
    Comments.create_comment(to_string(pr_number), notice(context.prefix), request_fun: context.request_fun, token: context.token)
  end

  defp notice(prefix) do
    """
    #{@notice_marker}
    ## Hardware verification required

    CI cannot exercise this PR's hardware-dependent acceptance criteria. A configured human operator must perform the physical verification and apply `#{HardwareVerification.verified_label(prefix)}` before this ticket can reach `done`; Aiur records the authenticated label event as the sign-off.
    """
  end

  defp notice_comment?(%{"body" => body}) when is_binary(body), do: String.contains?(body, @notice_marker)
  defp notice_comment?(_comment), do: false

  defp fetch_timeline_events(context) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{context.issue_number}/timeline?per_page=100"
    fetch_timeline_pages(context.request_fun, context.token, url, @timeline_page_limit, [])
  end

  defp fetch_timeline_pages(_request_fun, _token, _url, 0, _events),
    do: {:error, {:operator_signoff_event_required, :timeline_page_limit_exceeded}}

  defp fetch_timeline_pages(request_fun, token, url, pages_left, events) do
    case request_fun.(%{method: :get, url: url, token: token, max_response_bytes: @timeline_response_limit}) do
      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, events ++ page}
          next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events ++ page)
        end

      {:ok, %{status: _status} = response} ->
        {:error, {:operator_signoff_event_required, Errors.github_status_error(response)}}

      {:error, reason} ->
        {:error, {:operator_signoff_event_required, Errors.classify_error({:error, reason})}}

      _ ->
        {:error, {:operator_signoff_event_required, :invalid_timeline_response}}
    end
  end

  defp latest_signoff_actor(events, label) when is_list(events) do
    events
    |> Enum.filter(&signoff_event?(&1, label))
    |> Enum.map(&{event_sort_key(&1), actor_login(&1)})
    |> Enum.filter(fn {sort_key, actor} -> not is_nil(sort_key) and is_binary(actor) end)
    |> case do
      [] -> {:error, {:operator_signoff_event_required, :missing_verified_label_event}}
      signed_events -> {:ok, signed_events |> Enum.max_by(&elem(&1, 0)) |> elem(1)}
    end
  end

  defp latest_signoff_actor(_events, _label), do: {:error, {:operator_signoff_event_required, :invalid_timeline_response}}

  defp signoff_event?(event, label) when is_map(event) do
    (Map.get(event, "event") || Map.get(event, "type")) == "labeled" and
      case_insensitive_equal?(get_in(event, ["label", "name"]), label)
  end

  defp signoff_event?(_event, _label), do: false

  defp event_sort_key(%{"created_at" => created_at, "id" => id}) when is_binary(created_at) do
    with {:ok, timestamp, _offset} <- DateTime.from_iso8601(created_at),
         event_id when is_integer(event_id) <- normalize_event_id(id) do
      {DateTime.to_unix(timestamp, :microsecond), event_id}
    else
      _ -> nil
    end
  end

  defp event_sort_key(_event), do: nil

  defp normalize_event_id(id) when is_integer(id) and id >= 0, do: id

  defp normalize_event_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp normalize_event_id(_id), do: nil

  defp actor_login(event), do: get_in(event, ["actor", "login"])

  defp case_insensitive_equal?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp case_insensitive_equal?(_left, _right), do: false

  defp operator_authorized?(actor, context) do
    authorizer = Keyword.get(context.opts, :operator_authorized?, &Config.human_merger_allowed?/1)
    authorizer.(actor)
  end
end
