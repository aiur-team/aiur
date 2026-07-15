defmodule Aiur.GitHub.Issues do
  @moduledoc """
  GitHub issue fetch and normalization domain.
  """

  require Logger
  alias Aiur.{Config, GitHub, Issue, TrackerIdentity}
  alias Aiur.GitHub.{DependenciesApi, DependencyCache, Errors, Labels, StatePolicy, Transport}

  @dependency_fetch_budget 20
  @dependency_fetch_concurrency 4
  @dependency_poll_deadline_ms 5_000
  @dependency_cache_ttl_ms 60_000
  @dependency_rate_limit_floor 50

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    fetch_issues_by_states(Config.active_states(), opts)
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    if state_names == [], do: {:ok, []}, else: do_fetch_issues_by_states(state_names, opts)
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    if issue_ids == [], do: {:ok, []}, else: do_fetch_issue_states_by_ids(issue_ids, opts)
  end

  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      case request_fun.(%{method: :get, url: url, token: token}) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: _status} = response} -> {:error, Errors.github_status_error(response)}
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      end
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

  @spec do_fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_states(state_names, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      labels = Enum.map(state_names, &StatePolicy.state_label(prefix, &1))

      with {:ok, issues} <- fetch_issues_for_each_label(labels, request_fun, token, owner, repo, prefix) do
        opts = Keyword.put_new(opts, :dependency_cache_namespace, {owner, repo})
        hydrate_blocked_by(issues, prefix, request_fun, opts)
      end
    end
  end

  @spec do_fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      with {:ok, issues} <- do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
        opts =
          opts
          |> Keyword.put_new(:dependency_cache_namespace, {owner, repo})
          |> Keyword.put(:force_dependency_refresh?, true)

        hydrate_blocked_by(issues, prefix, request_fun, opts)
      end
    end
  end

  # Dependency data has an explicit known/unknown bit. A bounded poll refreshes
  # the oldest cache entries first; any issue not refreshed within the budget
  # remains unknown and therefore cannot dispatch or trigger dependency removal.
  # The ID-list path forces a refresh so the last pre-dispatch check never trusts
  # a cached empty list.
  @spec hydrate_blocked_by([Issue.t()], String.t(), function(), keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  defp hydrate_blocked_by(issues, prefix, request_fun, opts) do
    now_fun = Keyword.get(opts, :dependency_now_fun, fn -> System.monotonic_time(:millisecond) end)
    now_ms = now_fun.()
    namespace = Keyword.fetch!(opts, :dependency_cache_namespace)

    case DependencyCache.active_backoff(namespace, now_ms) do
      nil -> refresh_and_hydrate_dependencies(issues, prefix, request_fun, namespace, now_ms, now_fun, opts)
      reason -> {:error, reason}
    end
  end

  defp refresh_and_hydrate_dependencies(issues, prefix, request_fun, namespace, now_ms, now_fun, opts) do
    ttl_ms = Keyword.get(opts, :dependency_cache_ttl_ms, @dependency_cache_ttl_ms)
    force_refresh? = Keyword.get(opts, :force_dependency_refresh?, false)
    cache_entries = Map.new(issues, &{&1.id, DependencyCache.get(namespace, &1.id)})

    to_refresh =
      issues
      |> Enum.filter(fn issue ->
        force_refresh? or not cache_entry_fresh?(cache_entries[issue.id], issue, now_ms, ttl_ms)
      end)
      |> Enum.sort_by(&dependency_refresh_sort_key(&1, cache_entries[&1.id]))
      |> Enum.take(Keyword.get(opts, :dependency_fetch_budget, @dependency_fetch_budget))

    case refresh_dependency_entries(to_refresh, prefix, request_fun, namespace, now_fun, opts) do
      {:ok, refreshed_ids} ->
        {:ok, apply_dependency_cache(issues, namespace, now_fun.(), ttl_ms, force_refresh?, refreshed_ids)}

      {:error, reason} ->
        maybe_store_rate_limit_backoff(namespace, now_fun.(), reason, opts)
        {:error, reason}
    end
  end

  defp dependency_refresh_sort_key(issue, nil), do: {0, 0, issue_id_sort_key(issue.id)}

  defp dependency_refresh_sort_key(issue, entry) do
    {1, Map.get(entry, :checked_at_ms, 0), issue_id_sort_key(issue.id)}
  end

  defp issue_id_sort_key(issue_id) do
    case Integer.parse(to_string(issue_id)) do
      {number, ""} -> {0, number}
      _ -> {1, to_string(issue_id)}
    end
  end

  defp cache_entry_fresh?(nil, _issue, _now_ms, _ttl_ms), do: false

  defp cache_entry_fresh?(entry, issue, now_ms, ttl_ms) do
    checked_at_ms = Map.get(entry, :checked_at_ms)

    is_integer(checked_at_ms) and
      now_ms - checked_at_ms >= 0 and
      now_ms - checked_at_ms < ttl_ms and
      Map.get(entry, :source_updated_at) == issue.updated_at
  end

  defp refresh_dependency_entries([], _prefix, _request_fun, _namespace, _now_fun, _opts),
    do: {:ok, MapSet.new()}

  defp refresh_dependency_entries(issues, prefix, request_fun, namespace, now_fun, opts) do
    deadline_ms = now_fun.() + Keyword.get(opts, :dependency_poll_deadline_ms, @dependency_poll_deadline_ms)
    concurrency = Keyword.get(opts, :dependency_fetch_concurrency, @dependency_fetch_concurrency)

    issues
    |> Enum.chunk_every(concurrency)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn batch, {:ok, refreshed_ids} ->
      refresh_dependency_batch_before_deadline(
        batch,
        refreshed_ids,
        prefix,
        request_fun,
        namespace,
        now_fun,
        deadline_ms,
        opts
      )
    end)
  end

  defp refresh_dependency_batch_before_deadline(
         batch,
         refreshed_ids,
         prefix,
         request_fun,
         namespace,
         now_fun,
         deadline_ms,
         opts
       ) do
    remaining_ms = deadline_ms - now_fun.()

    if remaining_ms <= 0 do
      {:halt, dependency_deadline_error(deadline_ms)}
    else
      case refresh_dependency_batch(batch, prefix, request_fun, namespace, now_fun, remaining_ms, opts) do
        {:ok, batch_ids} -> {:cont, {:ok, MapSet.union(refreshed_ids, batch_ids)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end
  end

  defp refresh_dependency_batch(batch, prefix, request_fun, namespace, now_fun, timeout_ms, opts) do
    run_fetch = fn issue -> fetch_issue_blockers(issue, prefix, request_fun) end
    task_opts = [max_concurrency: length(batch), timeout: timeout_ms, on_timeout: :kill_task]

    result =
      batch
      |> async_stream_blocked_by(run_fetch, task_opts)
      |> Enum.zip(batch)
      |> Enum.reduce(%{error: nil, refreshed_ids: MapSet.new(), rate_meta: %{remaining: nil, reset_at: nil}}, fn
        {{:ok, {:ok, blockers, rate_meta}}, issue}, acc ->
          :ok =
            DependencyCache.put(namespace, issue.id, %{
              blockers: blockers,
              checked_at_ms: now_fun.(),
              source_updated_at: issue.updated_at
            })

          %{
            acc
            | refreshed_ids: MapSet.put(acc.refreshed_ids, issue.id),
              rate_meta: merge_rate_meta(acc.rate_meta, rate_meta)
          }

        {{:ok, {:error, reason}}, _issue}, %{error: nil} = acc ->
          %{acc | error: reason}

        {{:ok, {:error, _reason}}, _issue}, acc ->
          acc

        {{:exit, reason}, issue}, %{error: nil} = acc ->
          %{acc | error: dependency_task_exit_error(issue.id, reason)}

        {{:exit, _reason}, _issue}, acc ->
          acc
      end)

    cond do
      result.error != nil -> {:error, result.error}
      rate_budget_exhausted?(result.rate_meta, opts) -> {:error, rate_budget_error(result.rate_meta, opts)}
      true -> {:ok, result.refreshed_ids}
    end
  end

  defp apply_dependency_cache(issues, namespace, now_ms, ttl_ms, force_refresh?, refreshed_ids) do
    Enum.map(issues, fn issue ->
      entry = DependencyCache.get(namespace, issue.id)
      fresh? = cache_entry_fresh?(entry, issue, now_ms, ttl_ms)
      known? = fresh? and (not force_refresh? or MapSet.member?(refreshed_ids, issue.id))

      %{
        issue
        | blocked_by: if(entry, do: entry.blockers, else: []),
          blocked_by_known?: known?
      }
    end)
  end

  defp async_stream_blocked_by(to_hydrate, run_fetch, task_opts) do
    case Process.whereis(Aiur.TaskSupervisor) do
      pid when is_pid(pid) ->
        pid
        |> Task.Supervisor.async_stream_nolink(to_hydrate, run_fetch, task_opts)
        |> Enum.to_list()

      nil ->
        previous_trap_exit = Process.flag(:trap_exit, true)

        try do
          to_hydrate
          |> Task.async_stream(run_fetch, task_opts)
          |> Enum.to_list()
        after
          Process.flag(:trap_exit, previous_trap_exit)
        end
    end
  end

  defp fetch_issue_blockers(%Issue{id: issue_id}, prefix, request_fun) do
    case DependenciesApi.fetch_blocked_by_with_meta(issue_id, request_fun: request_fun) do
      {:ok, blockers, rate_meta} ->
        normalized =
          blockers
          |> Enum.map(&normalize_blocker(&1, prefix))
          |> Enum.reject(&(is_nil(&1) or &1.id == issue_id))

        {:ok, normalized, rate_meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_blocker(%{"number" => number, "labels" => labels} = gh_issue, prefix)
       when is_integer(number) and number > 0 and is_list(labels) do
    label_names =
      Enum.flat_map(labels, fn
        %{"name" => name} when is_binary(name) -> [name]
        _malformed -> []
      end)

    %{
      id: Integer.to_string(number),
      identifier: Integer.to_string(number),
      state: extract_state(gh_issue, label_names, prefix)
    }
  end

  # A malformed/non-map entry in the API response (unexpected shape,
  # truncated payload) is dropped rather than raising -- one bad blocker
  # entry must not crash the whole poll cycle.
  defp normalize_blocker(_gh_issue, _prefix), do: nil

  defp merge_rate_meta(left, right) do
    %{
      remaining: min_remaining(left.remaining, right.remaining),
      reset_at: right.reset_at || left.reset_at
    }
  end

  defp min_remaining(nil, remaining), do: remaining
  defp min_remaining(remaining, nil), do: remaining
  defp min_remaining(left, right), do: min(left, right)

  defp rate_budget_exhausted?(%{remaining: remaining}, opts) when is_integer(remaining) do
    remaining <= Keyword.get(opts, :dependency_rate_limit_floor, @dependency_rate_limit_floor)
  end

  defp rate_budget_exhausted?(_rate_meta, _opts), do: false

  defp rate_budget_error(rate_meta, opts) do
    retry_after = seconds_until_reset(rate_meta.reset_at, opts)

    {:github, :rate_limited,
     %{
       remaining: rate_meta.remaining,
       reset_at: rate_meta.reset_at,
       retry_after: retry_after,
       reason: :dependency_rate_budget
     }}
  end

  defp maybe_store_rate_limit_backoff(namespace, now_ms, {:github, :rate_limited, detail} = reason, opts) do
    delay_ms = rate_limit_delay_ms(detail, opts)
    DependencyCache.put_backoff(namespace, now_ms + delay_ms, reason)
  end

  defp maybe_store_rate_limit_backoff(_namespace, _now_ms, _reason, _opts), do: :ok

  defp rate_limit_delay_ms(detail, opts) do
    cond do
      is_integer(detail[:retry_after]) and detail[:retry_after] > 0 -> detail[:retry_after] * 1_000
      is_integer(detail[:poll_interval]) and detail[:poll_interval] > 0 -> detail[:poll_interval] * 1_000
      seconds_until_reset(detail[:reset_at], opts) > 0 -> seconds_until_reset(detail[:reset_at], opts) * 1_000
      true -> 1_000
    end
  end

  defp seconds_until_reset(reset_at, opts) when is_binary(reset_at) do
    wall_now_fun = Keyword.get(opts, :dependency_wall_now_fun, &DateTime.utc_now/0)

    case DateTime.from_iso8601(reset_at) do
      {:ok, reset_at, _offset} ->
        max(DateTime.diff(reset_at, wall_now_fun.(), :second), 0)

      _ ->
        0
    end
  end

  defp seconds_until_reset(_reset_at, _opts), do: 0

  defp dependency_deadline_error(deadline_ms) do
    {:error, {:github, :timeout, %{reason: :dependency_hydration_deadline, deadline_ms: deadline_ms}}}
  end

  defp dependency_task_exit_error(issue_id, reason) do
    {:github, :timeout, %{reason: {:dependency_hydration_task_exit, reason}, issue_id: issue_id}}
  end

  @spec do_list_issues(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def do_list_issues(request_fun, url, token, owner, repo, prefix) do
    with {:ok, issues, _next_url} <- fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      {:ok, issues}
    end
  end

  defp fetch_label_issue_pages(request_fun, url, token, owner, repo, prefix, acc) do
    with {:ok, issues, next_url} <- fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
      case next_url do
        nil -> {:ok, acc ++ issues}
        next_url -> fetch_label_issue_pages(request_fun, next_url, token, owner, repo, prefix, acc ++ issues)
      end
    end
  end

  defp fetch_label_issue_page(request_fun, url, token, owner, repo, prefix) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        {:ok, Enum.map(body, &normalize_issue(&1, owner, repo, prefix)), Transport.parse_next_page_url(Map.get(response, :headers, []))}

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
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix) | acc]}}

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
      paused: paused_label?(label_names, prefix),
      blocked_by_known?: false,
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

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

  defp tracker_identity(gh_issue, owner, repo) do
    case GitHub.Config.configured_repo() do
      {:ok, {configured_owner, configured_repo}} ->
        case TrackerIdentity.from_github(gh_issue, {configured_owner, configured_repo}, {owner, repo}) do
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
