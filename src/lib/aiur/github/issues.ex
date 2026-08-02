defmodule Aiur.GitHub.Issues do
  @moduledoc """
  GitHub issue fetch and normalization domain.
  """

  require Logger
  alias Aiur.{Alerts, BuildOrder.Bounded, Config, GitHub, HardwareVerification, Issue, TrackerIdentity}
  alias Aiur.GitHub.{BlockerCache, DependenciesApi, DispatchAuthorization, Errors, HardwareVerificationGate, Labels, StatePolicy, Transport}

  @max_issue_response_bytes 65_536
  # A dependency lookup can require up to four timeline pages to authenticate
  # a passing hardware blocker. Reserve that worst case from one total poll
  # budget rather than multiplying it by the number of candidate issues.
  @max_blocker_hydration_requests_per_poll 20
  @max_timeline_requests_per_blocker 4

  @spec max_issue_response_bytes() :: pos_integer()
  def max_issue_response_bytes, do: @max_issue_response_bytes

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    fetch_issues_by_states(Config.active_states(), opts)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- raw_repository(opts),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{
             method: :get,
             url: url,
             token: token,
             max_response_bytes: @max_issue_response_bytes
           }) do
        {:ok, %{private: %{aiur_response_too_large: true}, status: status} = response}
        when status != 200 ->
          {:error, Errors.github_status_error(response)}

        {:ok, %{private: %{aiur_response_too_large: true}}} ->
          {:error, :github_issue_response_too_large}

        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200}} ->
          {:error, :invalid_github_issue_response}

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  defp raw_repository(opts) do
    case Keyword.fetch(opts, :repository) do
      {:ok, {owner, repo}} ->
        repository_components(owner, repo)

      {:ok, _invalid_repository} ->
        {:error, :invalid_github_repository}

      :error ->
        with {:ok, {owner, repo}} <- Transport.parse_repo() do
          repository_components(owner, repo)
        end
    end
  end

  defp repository_components(owner, repo) do
    case Bounded.github_repository_components(owner, repo) do
      {:ok, repository} -> {:ok, repository}
      :error -> {:error, :invalid_github_repository}
    end
  end

  @spec fetch_issues_for_each_label(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
    Enum.reduce_while(labels, {:ok, %{}}, fn label, {:ok, acc} ->
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues?labels=#{URI.encode(label)}&state=open&per_page=100"

      reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc)
    end)
    |> case do
      {:ok, map} -> {:ok, Map.values(map)}
      error -> error
    end
  end

  @spec reduce_label_issues(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  def reduce_label_issues(request_fun, url, token, owner, repo, prefix, acc) do
    case fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, []) do
      {:ok, issues} ->
        merged = Map.merge(acc, Map.new(issues, &{&1.id, &1}), fn _k, v, _new -> v end)
        {:cont, {:ok, merged}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  @spec do_fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_states(state_names, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      labels = Enum.map(state_names, &StatePolicy.state_label(prefix, &1))

      with {:ok, issues} <-
             fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix),
           {:ok, issues} <- attach_blockers(issues, request_fun, token, owner, repo, prefix, opts) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @spec do_fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      with {:ok, issues} <-
             do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix),
           {:ok, issues} <- attach_blockers(issues, request_fun, token, owner, repo, prefix, opts) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @spec do_list_issues(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_list_issues(request_fun, url, token, owner, repo, prefix) do
    with {:ok, issues, _next_url} <-
           fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      {:ok, issues}
    end
  end

  defp fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, acc) do
    with {:ok, issues, next_url} <-
           fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      case next_url do
        nil ->
          {:ok, acc ++ issues}

        next_url ->
          fetch_label_issue_pages(
            request_fun,
            next_url,
            token,
            owner,
            repo,
            prefix,
            acc ++ issues
          )
      end
    end
  end

  defp fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")

        {:ok, Enum.map(body, &normalize_issue(&1, owner, repo, prefix, revision)), Transport.parse_next_page_url(Map.get(response, :headers, []))}

      {:ok, %{status: status} = response} ->
        Logger.error("GitHub API request failed status=#{status}")
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec do_fetch_issues_by_id_list(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
    result =
      Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
        url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_id}"
        reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc)
      end)

    case result do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec reduce_fetch_issue(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [Issue.t()]
        ) :: {:cont, {:ok, [Issue.t()]}} | {:halt, {:error, term()}}
  def reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_map(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix, revision) | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: _status} = response} ->
        {:halt, {:error, Errors.github_status_error(response)}}

      {:error, reason} ->
        {:halt, {:error, Errors.classify_error({:error, reason})}}
    end
  end

  @spec normalize_issue(map(), String.t(), String.t(), String.t()) :: Issue.t()
  def normalize_issue(gh_issue, owner, repo, prefix) when is_map(gh_issue) do
    normalize_issue(gh_issue, owner, repo, prefix, nil)
  end

  defp normalize_issue(gh_issue, owner, repo, prefix, dispatch_revision) when is_map(gh_issue) do
    number = gh_issue["number"]
    labels = gh_issue["labels"] || []
    label_names = Enum.map(labels, &(&1["name"] || ""))

    %Issue{
      id: to_string(number),
      identifier: to_string(number),
      tracker_identity: tracker_identity(gh_issue, owner, repo),
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: extract_priority(label_names),
      state: extract_state(gh_issue, label_names, prefix),
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      creator_login: get_in(gh_issue, ["user", "login"]),
      dispatch_revision: dispatch_revision,
      dispatch_authorized?: false,
      paused: paused_label?(label_names, prefix),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  defp attach_blockers(issues, request_fun, token, owner, repo, prefix, opts) do
    cache? = Keyword.get(opts, :cache_blockers, not Keyword.has_key?(opts, :request_fun))
    cache_opts = Keyword.take(opts, [:now_ms, :ttl_ms])

    refreshable_ids =
      if cache? do
        Enum.flat_map(issues, fn issue ->
          case BlockerCache.cached(issue.id, cache_opts) do
            {:fresh, _blockers} -> []
            _ -> [issue.id]
          end
        end)
      else
        Enum.map(issues, & &1.id)
      end

    scheduled_refreshes =
      BlockerCache.scheduled_refreshes(refreshable_ids, @max_blocker_hydration_requests_per_poll)

    {enriched, _remaining_requests} =
      Enum.map_reduce(issues, @max_blocker_hydration_requests_per_poll, fn issue, remaining_requests ->
        {blockers, remaining_requests} =
          hydrate_blockers(
            issue,
            request_fun,
            cache?,
            Keyword.put_new(opts, :token, token),
            remaining_requests,
            MapSet.member?(scheduled_refreshes, issue.id),
            owner,
            repo,
            prefix
          )

        normalized = Enum.map(blockers, &normalize_blocker(&1, owner, repo, prefix))
        {%{issue | blocked_by: normalized}, remaining_requests}
      end)

    {:ok, enriched}
  end

  defp hydrate_blockers(issue, request_fun, true, opts, remaining_requests, scheduled?, owner, repo, prefix) do
    cache_opts = Keyword.take(opts, [:now_ms, :ttl_ms])

    case BlockerCache.cached(issue.id, cache_opts) do
      {:fresh, blockers} ->
        {blockers, remaining_requests}

      stale_or_missing when not scheduled? or remaining_requests == 0 ->
        blocker_hydration_deferred(issue, stale_or_missing)
        {deferred_blockers(stale_or_missing), remaining_requests}

      _refreshable ->
        fetcher = fn -> DependenciesApi.fetch_blocked_by(issue.id, request_fun: request_fun) end
        hydrate_refreshable_blockers(issue, fetcher, cache_opts, remaining_requests, request_fun, token_for(opts), owner, repo, prefix, opts)
    end
  end

  defp hydrate_blockers(issue, request_fun, false, opts, remaining_requests, scheduled?, owner, repo, prefix) do
    if scheduled? and remaining_requests > 0 do
      hydrate_uncached_blockers(issue, request_fun, opts, remaining_requests, owner, repo, prefix)
    else
      blocker_hydration_deferred(issue, :missing)
      {[unknown_blocker()], remaining_requests}
    end
  end

  defp hydrate_uncached_blockers(issue, request_fun, opts, remaining_requests, owner, repo, prefix) do
    case DependenciesApi.fetch_blocked_by(issue.id, request_fun: request_fun) do
      {:ok, blockers} when is_list(blockers) ->
        annotate_blocker_signoffs(blockers, issue, request_fun, token_for(opts), owner, repo, prefix, opts, remaining_requests - 1)

      {:error, reason} ->
        blocker_hydration_warning(issue, reason)
        {[unknown_blocker()], remaining_requests - 1}
    end
  end

  defp hydrate_refreshable_blockers(issue, fetcher, cache_opts, remaining_requests, request_fun, token, owner, repo, prefix, opts) do
    case BlockerCache.fetch(issue.id, fetcher, cache_opts) do
      {:ok, blockers} ->
        {annotated, remaining_requests} =
          annotate_blocker_signoffs(blockers, issue, request_fun, token, owner, repo, prefix, opts, remaining_requests - 1)

        :ok = BlockerCache.put(issue.id, annotated, cache_opts)
        {annotated, remaining_requests}

      {:stale, blockers, reason} ->
        blocker_hydration_warning(issue, reason)
        {[unknown_blocker() | blockers], remaining_requests - 1}

      {:error, reason} ->
        blocker_hydration_warning(issue, reason)
        {[unknown_blocker()], remaining_requests - 1}
    end
  end

  defp annotate_blocker_signoffs(blockers, issue, request_fun, token, owner, repo, prefix, opts, remaining_requests) do
    {annotated, remaining_requests} =
      Enum.map_reduce(blockers, remaining_requests, fn blocker, remaining_requests ->
        annotate_blocker_signoff(blocker, request_fun, token, owner, repo, prefix, opts, remaining_requests)
      end)

    if Enum.any?(annotated, &Map.get(&1, :operator_signoff_deferred?, false)) do
      blocker_hydration_deferred(issue, :timeline_budget_exhausted)
    end

    {annotated, remaining_requests}
  end

  defp unknown_blocker, do: %{"state" => nil, "labels" => []}

  defp deferred_blockers({:stale, blockers}), do: [unknown_blocker() | blockers]
  defp deferred_blockers(_missing), do: [unknown_blocker()]

  defp blocker_hydration_deferred(issue, cache_state) do
    Logger.info("Deferring GitHub dependency hydration issue=#{issue.identifier} state=#{inspect(cache_state)}")

    case Alerts.emit_system("ticket.#{issue.identifier}.operator.blocker_hydration_deferred",
           issue: issue.identifier,
           reason: "GitHub dependency verification was deferred by the shared request budget; dispatch is failing closed.",
           needs_attention: false,
           severity: "info"
         ) do
      :ok -> :ok
      {:error, alert_reason} -> Logger.error("Could not publish blocker hydration deferral issue=#{issue.identifier} reason=#{inspect(alert_reason)}")
    end
  end

  defp blocker_hydration_warning(issue, reason) do
    Logger.warning("Failing closed after GitHub dependency hydration failure issue=#{issue.identifier} reason=#{inspect(reason)}")

    case Alerts.emit_system("ticket.#{issue.identifier}.operator.blocker_hydration_failed",
           issue: issue.identifier,
           reason: "GitHub dependency data could not be refreshed; dispatch is failing closed for this ticket.",
           needs_attention: true,
           severity: "warning"
         ) do
      :ok -> :ok
      {:error, alert_reason} -> Logger.error("Could not publish blocker hydration alert issue=#{issue.identifier} reason=#{inspect(alert_reason)}")
    end
  end

  defp normalize_blocker(blocker, owner, repo, prefix) when is_map(blocker) do
    normalized = normalize_issue(blocker, owner, repo, prefix, nil)

    %{
      id: normalized.id,
      identifier: normalized.identifier,
      title: normalized.title,
      description: normalized.description,
      state: normalized.state,
      labels: normalized.labels,
      operator_signoff_valid?: Map.get(blocker, :operator_signoff_valid?, false),
      operator_signoff_identity: Map.get(blocker, :operator_signoff_identity),
      operator_signoff_deferred?: Map.get(blocker, :operator_signoff_deferred?, false)
    }
  end

  defp normalize_blocker(_blocker, _owner, _repo, _prefix), do: %{}

  defp annotate_blocker_signoff(blocker, request_fun, token, owner, repo, prefix, opts, remaining_requests)
       when is_map(blocker) do
    if HardwareVerification.outcome_label(blocker, prefix) == HardwareVerification.passed_label(prefix) do
      if remaining_requests < @max_timeline_requests_per_blocker do
        {blocker |> Map.put(:operator_signoff_valid?, false) |> Map.put(:operator_signoff_deferred?, true), remaining_requests}
      else
        context = %{request_fun: request_fun, token: token, owner: owner, repo: repo, issue_number: blocker["number"], prefix: prefix, opts: opts}

        case HardwareVerificationGate.passing_operator_signoff_identity(context, blocker) do
          {:ok, identity} ->
            {blocker |> Map.put(:operator_signoff_valid?, true) |> Map.put(:operator_signoff_identity, identity), remaining_requests - @max_timeline_requests_per_blocker}

          {:error, _reason} ->
            {Map.put(blocker, :operator_signoff_valid?, false), remaining_requests - @max_timeline_requests_per_blocker}
        end
      end
    else
      {Map.put(blocker, :operator_signoff_valid?, false), remaining_requests}
    end
  end

  defp annotate_blocker_signoff(blocker, _request_fun, _token, _owner, _repo, _prefix, _opts, remaining_requests),
    do: {blocker, remaining_requests}

  defp token_for(opts), do: Keyword.get(opts, :token, "")

  @spec extract_state(map(), [String.t()], String.t()) :: String.t() | nil
  def extract_state(%{"state" => "closed"}, _label_names, _prefix), do: "Closed"

  def extract_state(_gh_issue, label_names, prefix) do
    prefix_colon = normalize_label_name("#{prefix}:")
    Enum.find_value(label_names, &state_label_suffix(&1, prefix_colon))
  end

  @spec extract_priority([String.t()]) :: integer() | nil
  def extract_priority(label_names), do: Enum.find_value(label_names, &parse_priority_label/1)

  @spec parse_priority_label(String.t()) :: integer() | nil
  def parse_priority_label(name) do
    case Regex.run(~r/^priority:(\d+)$/, name) do
      [_, n] -> parse_priority_int(n)
      _ -> nil
    end
  end

  @spec parse_priority_int(String.t()) :: integer() | nil
  def parse_priority_int(n) do
    case Integer.parse(n) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  def parse_datetime(nil), do: nil

  def parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp state_label_suffix(name, prefix_colon) do
    normalized = normalize_label_name(name)

    if String.starts_with?(normalized, prefix_colon) do
      normalized
      |> String.replace_prefix(prefix_colon, "")
      |> state_suffix_unless_preserved()
    end
  end

  defp state_suffix_unless_preserved(suffix),
    do: unless(Labels.marker_suffix?(suffix), do: suffix)

  defp paused_label?(label_names, prefix) when is_list(label_names) do
    paused_label = normalize_label_name("#{prefix}:paused")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == paused_label
    end)
  end

  defp normalize_label_name(label) when is_binary(label),
    do: String.downcase(String.trim(label))

  defp normalize_label_name(_label), do: ""

  defp response_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: header_value(value)

      _ ->
        nil
    end)
  end

  defp response_header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: header_value(value)
    end)
  end

  defp response_header(_headers, _name), do: nil

  defp header_value([value | _]), do: header_value(value)
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_value), do: nil

  defp authorize_dispatches(issues, request_fun, token, owner, repo, prefix) do
    Enum.map(issues, fn issue ->
      DispatchAuthorization.authorize(
        issue,
        owner,
        repo,
        prefix,
        request_fun: request_fun,
        token: token
      )
    end)
  end

  defp tracker_identity(gh_issue, owner, repo) do
    case GitHub.Config.configured_repo() do
      {:ok, {configured_owner, configured_repo}} ->
        case TrackerIdentity.from_github(
               gh_issue,
               {configured_owner, configured_repo},
               {owner, repo}
             ) do
          {:ok, identity} ->
            identity

          {:error, reason} ->
            TrackerIdentity.unjoinable(reason,
              owner: configured_owner,
              repository: configured_repo,
              identifier: Map.get(gh_issue, "number")
            )
        end

      {:error, reason} ->
        TrackerIdentity.unjoinable(reason, identifier: Map.get(gh_issue, "number"))
    end
  end
end
