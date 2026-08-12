defmodule Aiur.GitHub.DispatchAuthorization do
  @moduledoc false

  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.GitHub.{Config, Errors, StatePolicy, Transport}

  @cache_key {__MODULE__, :timeline_cache}
  @max_cache_entries 1_000

  # A timeline page requests up to `per_page=100` events (see fetch_decision),
  # each of which embeds the full actor, label, and often issue objects
  # (measured ~2.5–3.5 KiB per event on real timelines). 512 KiB holds a full
  # 100-event page with headroom; the previous 64 KiB cap truncated real
  # timelines at ~20 events, which failed the `is_list/1` guard and was
  # misreported as an HTTP error with status 200 (#1454).
  @max_timeline_response_bytes 524_288
  @max_timeline_pages 4

  @spec authorize(Issue.t(), String.t(), String.t(), String.t(), keyword()) :: Issue.t()
  def authorize(issue, owner, repo, prefix, opts \\ [])

  def authorize(%Issue{state_labels: [_, _ | _] = state_labels} = issue, _owner, _repo, _prefix, _opts) do
    deny_ambiguous(issue, {:contradictory_state_labels, state_labels})
  end

  def authorize(%Issue{} = issue, owner, repo, prefix, opts) do
    allowed_users = allowed_users(opts)

    case trusted_creator(issue.creator_login, allowed_users) do
      true ->
        log_decision(:allow, issue, "creator", issue.creator_login, nil)
        %{issue | dispatch_authorized?: true}

      false ->
        authorize_label_applier(issue, owner, repo, prefix, allowed_users, opts)
    end
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp authorize_label_applier(issue, owner, repo, prefix, allowed_users, opts) do
    case trigger_label(issue, prefix) do
      {:ok, label} ->
        issue
        |> label_applier_decision(label, owner, repo, opts)
        |> apply_label_decision(issue, allowed_users)

      :error ->
        deny_ambiguous(issue, :missing_trigger_label)
    end
  end

  defp trigger_label(%Issue{state: state}, prefix) when is_binary(state) and state != "",
    do: {:ok, StatePolicy.state_label(prefix, state)}

  defp trigger_label(_issue, _prefix), do: :error

  defp label_applier_decision(issue, label, owner, repo, opts) do
    cached_decision(issue, label) || fetch_decision(issue, label, owner, repo, opts)
  end

  defp apply_label_decision({:verified, actor, event_id}, issue, allowed_users) do
    authorized? = member?(allowed_users, actor)

    log_decision(
      if(authorized?, do: :allow, else: :deny),
      issue,
      "label_applier",
      actor,
      event_id
    )

    %{issue | dispatch_authorized?: authorized?}
  end

  defp apply_label_decision({:ambiguous, reason}, issue, _allowed_users), do: deny_ambiguous(issue, reason)

  defp trusted_creator(login, allowed_users) when is_binary(login),
    do: member?(allowed_users, login)

  defp trusted_creator(_login, _allowed_users), do: false

  defp fetch_decision(issue, label, owner, repo, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    token = Keyword.get(opts, :token, Config.token())

    if is_binary(token) and token != "" do
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue.id}/timeline?per_page=100"

      case fetch_timeline_pages(request_fun, token, url, @max_timeline_pages, []) do
        {:ok, events} ->
          timeline_decision(issue, label, events)

        {:error, reason} ->
          {:ambiguous, reason}
      end
    else
      {:ambiguous, :missing_github_token}
    end
  end

  defp fetch_timeline_pages(_request_fun, _token, _url, 0, _events), do: {:error, :timeline_page_limit_exceeded}

  defp fetch_timeline_pages(request_fun, token, url, pages_left, events) do
    case request_fun.(%{method: :get, url: url, token: token, max_response_bytes: @max_timeline_response_bytes}) do
      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, events ++ page}
          next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events ++ page)
        end

      {:ok, %{status: 200}} ->
        # A 200 whose body is not a JSON list means the page was truncated at
        # @max_timeline_response_bytes by the transport (the body becomes ""),
        # or was otherwise malformed — not an HTTP failure. Name the real cause
        # instead of the self-contradictory `{:github, :http, %{status: 200}}`
        # (#1454).
        {:error, :timeline_truncated}

      {:ok, %{status: status} = response} ->
        {:error, {:timeline_fetch_failed, Errors.github_status_error(Map.put(response, :status, status))}}

      {:error, reason} ->
        {:error, {:timeline_fetch_failed, Errors.classify_error({:error, reason})}}

      _ ->
        {:error, :invalid_timeline_response}
    end
  end

  defp timeline_decision(issue, label, events) do
    case latest_label_event(events, label) do
      %{id: event_id, actor: actor} ->
        decision =
          if is_binary(actor),
            do: {:verified, actor, event_id},
            else: {:ambiguous, :missing_timeline_actor}

        cache_decision(issue, label, event_id, decision)
        decision

      :missing ->
        decision = {:ambiguous, :missing_label_event}
        cache_decision(issue, label, "missing", decision)
        decision

      :invalid ->
        decision = {:ambiguous, :missing_label_event_id}
        cache_decision(issue, label, "invalid", decision)
        decision
    end
  end

  defp latest_label_event(events, label) do
    if Enum.all?(events, &is_map/1), do: matching_label_event(events, label), else: :invalid
  end

  defp matching_label_event(events, label) do
    events
    |> Enum.reduce_while({:ok, []}, &collect_matching_event(&1, label, &2))
    |> latest_matching_event()
  end

  defp collect_matching_event(event, label, {:ok, matching}) do
    if labeled_with_name?(event, label) do
      case event_sort_key(event) do
        {:ok, sort_key} -> {:cont, {:ok, [{sort_key, event} | matching]}}
        :error -> {:halt, :invalid}
      end
    else
      {:cont, {:ok, matching}}
    end
  end

  defp latest_matching_event({:ok, []}), do: :missing

  defp latest_matching_event({:ok, matching}) do
    {_sort_key, %{"id" => id} = event} = Enum.max_by(matching, &elem(&1, 0))
    %{id: to_string(id), actor: get_in(event, ["actor", "login"])}
  end

  defp latest_matching_event(:invalid), do: :invalid

  defp labeled_with_name?(event, label) do
    (Map.get(event, "event") || Map.get(event, "type")) == "labeled" and
      label_matches?(get_in(event, ["label", "name"]), label)
  end

  defp event_sort_key(%{"created_at" => created_at, "id" => id}) when is_binary(created_at) do
    with {:ok, timestamp, _offset} <- DateTime.from_iso8601(created_at),
         event_id when is_integer(event_id) <- event_id_sort_key(id) do
      {:ok, {DateTime.to_unix(timestamp, :microsecond), event_id}}
    else
      _ -> :error
    end
  end

  defp event_sort_key(_event), do: :error

  defp event_id_sort_key(id) when is_integer(id) and id >= 0, do: id

  defp event_id_sort_key(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp event_id_sort_key(_id), do: nil

  defp label_matches?(event_label, label) when is_binary(event_label),
    do: String.downcase(String.trim(event_label)) == String.downcase(label)

  defp label_matches?(_event_label, _label), do: false

  defp cached_decision(%Issue{id: id, updated_at: updated_at}, label) when is_binary(id) do
    cache = cache()
    fingerprint = {id, label, updated_at}

    with event_id when is_binary(event_id) <- Map.get(cache.fingerprints, fingerprint),
         decision when not is_nil(decision) <- Map.get(cache.decisions, {id, label, event_id}) do
      decision
    end
  end

  defp cached_decision(_issue, _label), do: nil

  defp cache_decision(
         %Issue{id: id, updated_at: updated_at},
         label,
         event_id,
         decision
       )
       when is_binary(id) do
    cache = cache()
    fingerprint = {id, label, updated_at}

    updated = %{
      fingerprints: Map.put(cache.fingerprints, fingerprint, event_id),
      decisions: Map.put(cache.decisions, {id, label, event_id}, decision),
      alerted: cache.alerted
    }

    :persistent_term.put(@cache_key, if(map_size(updated.decisions) > @max_cache_entries, do: %{fingerprints: %{}, decisions: %{}, alerted: %{}}, else: updated))
  end

  defp cache_decision(_issue, _label, _event_id, _decision), do: :ok

  defp allowed_users(opts) do
    opts
    |> Keyword.get(:allowed_users, Config.allowed_users())
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp member?(allowed_users, login),
    do: MapSet.member?(allowed_users, String.downcase(String.trim(login)))

  defp log_decision(decision, issue, source, actor, event_id, reason \\ nil) do
    Logger.info(
      "GitHub dispatch authorization decision=#{decision} issue_id=#{inspect(issue.id)} " <>
        "issue_identifier=#{inspect(issue.identifier)} " <>
        "creator=#{inspect(issue.creator_login)} source=#{source} actor=#{inspect(actor)} " <>
        "label_event_id=#{inspect(event_id)} reason=#{inspect(reason)}"
    )
  end

  defp deny_ambiguous(issue, reason) do
    log_decision(:deny, issue, "ambiguous", nil, nil, reason)
    maybe_alert_ambiguity(issue, reason)
    %{issue | dispatch_authorized?: false}
  end

  defp maybe_alert_ambiguity(%Issue{id: id, updated_at: updated_at} = issue, reason)
       when is_binary(id) do
    alert_key = {id, updated_at, reason}
    cache = cache()

    unless Map.has_key?(cache.alerted, alert_key) do
      alerted =
        cache.alerted
        |> bounded_alert_cache()
        |> Map.put(alert_key, true)

      :persistent_term.put(@cache_key, %{cache | alerted: alerted})
      alert_ambiguity(issue, reason)
    end
  end

  defp maybe_alert_ambiguity(issue, reason), do: alert_ambiguity(issue, reason)

  defp cache do
    :persistent_term.get(@cache_key, %{fingerprints: %{}, decisions: %{}, alerted: %{}})
  end

  defp bounded_alert_cache(alerted) when map_size(alerted) >= @max_cache_entries, do: %{}
  defp bounded_alert_cache(alerted), do: alerted

  defp alert_ambiguity(issue, reason) do
    Alerts.emit_custom(
      "github.dispatch_authorization.ambiguous",
      "Dispatch denied for issue #{issue.identifier || issue.id}: label provenance could not be verified (#{inspect(reason)}).",
      issue: issue.identifier || issue.id,
      reason: "GitHub dispatch authorization requires verified trigger-label provenance: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end
end
