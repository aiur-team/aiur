defmodule Aiur.Orchestrator.OptimisticGuardObservations do
  @moduledoc "Bounded confirming reads for optimistic blockers; failed reads never authorize parking."
  alias Aiur.{CodeHost, Issue, Tracker}

  @spec read([map()], integer(), keyword()) :: map()
  def read(records, now, opts) do
    records = Enum.reject(records, &(&1["status"] == "closed"))
    blockers = records |> Enum.flat_map(& &1["blockers"]) |> Enum.uniq_by(& &1["id"])
    max_age = Keyword.fetch!(opts, :observation_max_age_ms)
    force = Keyword.get(opts, :force_blocker)
    read_pr = Keyword.get(opts, :read_pr, &CodeHost.optimistic_blocker/2)
    closure = Keyword.get(opts, :closure, &Tracker.issue_closure/2)
    fetch = Keyword.get(opts, :fetch_issues, &Tracker.fetch_issue_states_by_ids/1)
    grace = Keyword.get(opts, :grace_ms, 600_000)
    stale = records |> Enum.flat_map(& &1["blockers"]) |> Enum.reject(&cache_usable?(&1, now, max_age, grace, force)) |> Enum.uniq_by(& &1["id"])
    stale_ids = MapSet.new(stale, & &1["id"])
    {edges, edge_cache} = edge_evidence(records, blockers, now, max_age, opts)
    dependents = for row <- records, row["status"] == "parked", do: row["ticket"]
    grace_refresh = for row <- records, blocker <- row["blockers"], grace_crossed?(blocker["suspect_since_ms"], get_in(blocker, ["guard_observation", "observed_at_ms"]), now, grace), do: blocker["id"]
    confirm = dependents ++ grace_refresh
    issues = Keyword.get(opts, :issues, %{})
    missing = Enum.map(stale, & &1["id"]) |> Enum.reject(&Map.has_key?(issues, &1))
    fetched = fetch_issues(Enum.uniq(missing ++ confirm), fetch)
    issues = Map.merge(fetched, Map.drop(issues, confirm))

    observations =
      Map.new(blockers, fn blocker ->
        id = blocker["id"]
        cached = decode(blocker["guard_observation"])
        observation = if MapSet.member?(stale_ids, id), do: observe(id, blocker, issues[id], now, max_age, read_pr, closure, opts), else: cached
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

    Enum.reduce(records, {%{}, %{}}, fn row, acc ->
      read_edge(row["ticket"], cached[row["ticket"]], now, max_age, read, acc)
    end)
  end

  defp read_edge(dep, entry, now, max_age, read, {edges, cache}) do
    fresh = edge_fresh?(entry, now, max_age)
    result = if fresh, do: {:ok, entry["ids"]}, else: safe_read(read, [dep])

    case result do
      {:ok, ids} ->
        at = if fresh, do: entry["observed_at_ms"], else: now
        {Map.put(edges, dep, MapSet.new(ids)), Map.put(cache, dep, %{"ids" => ids, "observed_at_ms" => at})}

      _ ->
        {Map.put(edges, dep, :unknown), cache}
    end
  end

  defp edge_fresh?(%{"observed_at_ms" => at, "ids" => ids}, now, max_age) when is_integer(at) and is_list(ids),
    do: at <= now and now - at < max_age

  defp edge_fresh?(_, _, _), do: false

  defp observe(id, blocker, issue, now, max_age, read_pr, closure, opts) do
    with {:ok, %{open?: open?, state_reason: reason}} <- safe_read(closure, [id, max_age]),
         true <- not open? or match?(%Issue{}, issue),
         {:ok, pr} <- safe_read(read_pr, [id, blocker["pr_number"]]) do
      labels = if issue, do: labels(issue, opts), else: []

      Map.merge(%{confirmed?: true, observed_at_ms: now, issue_open?: open?, state_reason: reason, labels: labels}, pr_facts(pr || %{}))
    else
      _ -> %{confirmed?: false}
    end
  end

  defp pr_facts(pr) do
    %{
      pr_state: pr["state"],
      pr_merged: pr["merged"],
      any_open_pr?: pr["state"] == "open",
      pr_number: pr["number"],
      pr_head_ref: get_in(pr, ["head", "ref"]),
      pr_head_sha: get_in(pr, ["head", "sha"]),
      pr_closed_at_ms: timestamp(pr["closed_at"])
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  @keys ~w(confirmed? observed_at_ms issue_open? state_reason labels pr_state pr_merged any_open_pr? pr_number pr_head_ref pr_head_sha pr_closed_at_ms edge_cache)a
  defp decode(map) when is_map(map), do: Map.new(@keys, &{&1, map[to_string(&1)]})
  defp decode(_), do: %{}
  defp fresh?(%{confirmed?: true, observed_at_ms: at}, now, max_age) when is_integer(at), do: at <= now and now - at < max_age
  defp fresh?(_, _, _), do: false
end
