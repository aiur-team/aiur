defmodule Aiur.Orchestrator.OptimisticGuardObservations do
  @moduledoc "Bounded confirming reads for optimistic blockers; failed reads never authorize parking."
  alias Aiur.{CodeHost, Issue, Tracker}

  @spec read([map()], integer(), keyword()) :: map()
  def read(records, now, opts) do
    records = Enum.reject(records, &(&1["status"] == "closed"))
    blockers = records |> Enum.flat_map(& &1["blockers"]) |> Enum.uniq_by(& &1["id"])
    max_age = Keyword.fetch!(opts, :observation_max_age_ms)
    force = Keyword.get(opts, :force_blocker)
    read_pr = Keyword.get(opts, :read_pr, &read_optimistic_pr/4)
    closure = Keyword.get(opts, :closure, &Tracker.issue_closure/2)
    fetch = Keyword.get(opts, :fetch_issues, &Tracker.fetch_issue_states_by_ids/1)
    grace = Keyword.get(opts, :grace_ms, 600_000)
    stale = records |> Enum.flat_map(& &1["blockers"]) |> Enum.reject(&cache_usable?(&1, now, max_age, grace, force)) |> Enum.uniq_by(& &1["id"])
    {edges, edge_cache, edge_reads} = edge_evidence(records, blockers, now, max_age, opts)
    stale_ids = MapSet.new(stale, & &1["id"]) |> MapSet.union(edge_removed_blockers(records, edges, edge_cache, edge_reads))
    dependents = for row <- records, row["status"] == "parked", do: row["ticket"]
    grace_refresh = for row <- records, blocker <- row["blockers"], grace_crossed?(blocker["suspect_since_ms"], get_in(blocker, ["guard_observation", "observed_at_ms"]), now, grace), do: blocker["id"]
    confirm = dependents ++ grace_refresh
    issues = Keyword.get(opts, :issues, %{})
    missing = stale_ids |> MapSet.to_list() |> Enum.reject(&Map.has_key?(issues, &1))
    fetched = fetch_issues(Enum.uniq(missing ++ confirm), fetch)
    issues = Map.merge(fetched, Map.drop(issues, confirm))

    observations =
      Map.new(blockers, fn blocker ->
        id = blocker["id"]
        cached = decode(blocker["guard_observation"])
        approval_check = approval_check?(records, blocker, force)
        read_context = %{max_age: max_age, read_pr: read_pr, closure: closure, approval_check: approval_check, conflicts_seen: conflict_count(records, id), opts: opts}
        observation = if MapSet.member?(stale_ids, id), do: observe(id, blocker, issues[id], now, read_context), else: cached
        observation = refresh_labels(observation, issues[id], opts)
        {id, observation |> Map.put(:edges, edges) |> Map.put(:edge_cache, edge_cache)}
      end)

    Map.put(observations, :dependents, Map.take(issues, dependents))
  end

  defp safe_read(reader, args) do
    apply(reader, args)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp cache_usable?(blocker, now, max_age, grace, force) do
    cached = decode(blocker["guard_observation"])
    blocker["id"] != force and fresh?(cached, now, max_age) and not grace_crossed?(blocker["suspect_since_ms"], cached[:observed_at_ms], now, grace)
  end

  defp grace_crossed?(since, observed_at, now, grace) when is_integer(since) and is_integer(observed_at),
    do: now >= since + grace and observed_at < since + grace

  defp grace_crossed?(_since, _observed_at, _now, _grace), do: false

  defp refresh_labels(%{issue_open?: true} = observation, %Issue{} = issue, opts), do: Map.put(observation, :labels, labels(issue, opts))
  defp refresh_labels(observation, _issue, _opts), do: observation

  defp labels(%Issue{} = issue, opts) do
    prefix = Keyword.get(opts, :label_prefix, "agent")
    Enum.map(Issue.label_names(issue), &String.replace_prefix(&1, prefix <> ":", "agent:"))
  end

  defp fetch_issues([], _fetch), do: %{}

  defp fetch_issues(ids, fetch) do
    case safe_read(fetch, [ids]) do
      {:ok, rows} -> Map.new(rows, &{to_string(&1.identifier), &1})
      _ -> %{}
    end
  end

  defp edge_evidence(records, blockers, now, max_age, opts) do
    read = Keyword.get(opts, :blocked_by, &Tracker.blocked_by/1)

    cached =
      Enum.reduce(blockers, %{}, fn blocker, acc ->
        Map.merge(acc, get_in(blocker, ["guard_observation", "edge_cache"]) || %{})
      end)

    Enum.reduce(records, {%{}, %{}, MapSet.new()}, fn row, acc ->
      read_edge(row["ticket"], cached[row["ticket"]], now, max_age, read, acc)
    end)
  end

  defp read_edge(dep, entry, now, max_age, read, {edges, cache, reads}) do
    fresh = edge_fresh?(entry, now, max_age)
    result = if fresh, do: {:ok, entry["ids"]}, else: safe_read(read, [dep])

    case result do
      {:ok, ids} ->
        at = if fresh, do: entry["observed_at_ms"], else: now
        reads = if fresh, do: reads, else: MapSet.put(reads, dep)
        {Map.put(edges, dep, MapSet.new(ids)), Map.put(cache, dep, %{"ids" => ids, "observed_at_ms" => at}), reads}

      _ ->
        {Map.put(edges, dep, :unknown), cache, reads}
    end
  end

  defp edge_fresh?(%{"observed_at_ms" => at, "ids" => ids}, now, max_age) when is_integer(at) and is_list(ids),
    do: at <= now and now - at < max_age

  defp edge_fresh?(_, _, _), do: false

  defp edge_removed_blockers(records, edges, edge_cache, edge_reads) do
    Enum.reduce(records, MapSet.new(), fn record, missing ->
      edge_removed_blocker_ids(
        record,
        Map.get(edges, record["ticket"]),
        Map.get(edge_cache, record["ticket"]),
        edge_reads,
        missing
      )
    end)
  end

  defp edge_removed_blocker_ids(record, %MapSet{} = ids, cache, edge_reads, missing) do
    edge_at = cache && cache["observed_at_ms"]

    Enum.reduce(record["blockers"], missing, fn blocker, acc ->
      if not MapSet.member?(ids, blocker["id"]) and
           edge_read_requires_blocker_refresh?(blocker, record["ticket"], edge_at, edge_reads) do
        MapSet.put(acc, blocker["id"])
      else
        acc
      end
    end)
  end

  defp edge_removed_blocker_ids(_record, _ids, _cache, _edge_reads, missing), do: missing

  defp edge_read_requires_blocker_refresh?(blocker, dependent, edge_at, edge_reads) do
    observation_at = get_in(blocker, ["guard_observation", "observed_at_ms"])

    MapSet.member?(edge_reads, dependent) or
      (is_integer(edge_at) and (not is_integer(observation_at) or observation_at < edge_at))
  end

  defp observe(id, blocker, issue, now, context) do
    with {:ok, %{open?: open?, state_reason: reason}} <- safe_read(context.closure, [id, context.max_age]),
         true <- not open? or match?(%Issue{}, issue),
         {:ok, pr} <- read_pr(context.read_pr, id, blocker["pr_number"], context.approval_check, context.conflicts_seen) do
      labels = if issue, do: labels(issue, context.opts), else: []

      Map.merge(%{confirmed?: true, observed_at_ms: now, issue_open?: open?, state_reason: reason, labels: labels}, pr_facts(pr || %{}))
    else
      _ -> %{confirmed?: false}
    end
  end

  defp read_optimistic_pr(id, number, approval_check, conflicts_seen),
    do: CodeHost.optimistic_blocker(id, number, approval_check?: approval_check, approval_conflicts_count: conflicts_seen)

  defp read_pr(reader, id, number, approval_check, conflicts_seen) when is_function(reader, 4),
    do: safe_read(reader, [id, number, approval_check, conflicts_seen])

  defp read_pr(reader, id, number, approval_check, _conflicts_seen) when is_function(reader, 3),
    do: safe_read(reader, [id, number, approval_check])

  defp read_pr(reader, id, number, _approval_check, _conflicts_seen), do: safe_read(reader, [id, number])

  defp approval_check?(records, blocker, force) do
    newly_conflicting? =
      Enum.any?(records, fn record ->
        case Enum.find(record["blockers"], &(&1["id"] == blocker["id"])) do
          nil ->
            false

          facts ->
            count = conflict_count([record], blocker["id"])

            count > (facts["conflicts_at_approval"] || 0) and
              count > (facts["approval_checked_conflicts"] || 0)
        end
      end)

    newly_conflicting? or blocker["id"] == force
  end

  defp conflict_count(records, blocker) do
    records
    |> Enum.filter(&Enum.any?(&1["blockers"], fn facts -> facts["id"] == blocker end))
    |> Enum.map(fn record ->
      reports = Enum.filter(record["integration_reports"] || [], &(&1["blocker"] == blocker and &1["conflict"] == true))
      if reports == [] and length(record["blockers"]) == 1, do: get_in(record, ["counters", "integrations_conflict"]) || 0, else: length(reports)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp pr_facts(pr) do
    %{
      pr_state: pr["state"],
      pr_merged: pr["merged"],
      pr_merged_at_ms: timestamp(pr["merged_at"]),
      any_open_pr?: pr["state"] == "open",
      pr_number: pr["number"],
      pr_head_ref: get_in(pr, ["head", "ref"]),
      pr_head_sha: get_in(pr, ["head", "sha"]),
      pr_closed_at_ms: timestamp(pr["closed_at"]),
      pr_approved?: get_in(pr, ["approval", :approved?]) == true or get_in(pr, ["approval", "approved?"]) == true,
      pr_mergeable?: get_in(pr, ["approval", :mergeable?]) == true or get_in(pr, ["approval", "mergeable?"]) == true,
      pr_approval_checked_conflicts: get_in(pr, ["approval", :checked_conflicts]) || get_in(pr, ["approval", "checked_conflicts"])
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  @keys ~w(confirmed? observed_at_ms issue_open? state_reason labels pr_state pr_merged pr_merged_at_ms any_open_pr? pr_number pr_head_ref pr_head_sha pr_closed_at_ms pr_approved? pr_mergeable? pr_approval_checked_conflicts edge_cache)a
  defp decode(map) when is_map(map), do: Map.new(@keys, &{&1, map[to_string(&1)]})
  defp decode(_), do: %{}
  defp fresh?(%{confirmed?: true, observed_at_ms: at}, now, max_age) when is_integer(at), do: at <= now and now - at < max_age
  defp fresh?(_, _, _), do: false
end
