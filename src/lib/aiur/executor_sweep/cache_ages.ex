defmodule Aiur.ExecutorSweep.CacheAges do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @spec for_repo(String.t(), String.t(), integer()) :: map()
  def for_repo(owner, repo, now_ms \\ System.system_time(:millisecond)) do
    pull_requests = subject_ages(:pull_request, owner, repo, now_ms)
    reviews = subject_ages(:pull_request_reviews, owner, repo, now_ms)

    %{
      pull_requests: Map.merge(pull_requests, reviews, fn _number, pr_age, review_age -> max(pr_age, review_age) end),
      merge_group_runs: merge_group_ages(owner, repo, now_ms),
      merge_group_evidence: merge_group_evidence(owner, repo, now_ms)
    }
  end

  @active_statuses ["queued", "in_progress", "waiting", "requested"]

  # LandingWatch keys each run page by its status listing ("base:status:page"). Most pages fit in
  # the store and hold a response map; only oversized pages get the compact age-index list (#5738).
  defp merge_group_evidence(owner, repo, now_ms) do
    entries = ResourceStore.list(:landing_merge_group_runs, owner, repo)

    page_entries =
      for {{_type, _owner, _repo, id}, entry} <- entries,
          {base, status, page, runs} <- page_runs(id, Map.get(entry, :data)),
          age = entry_age(entry, now_ms),
          is_integer(age),
          do: {base, status, page, age, runs}

    pages =
      page_entries
      |> Enum.reduce(%{}, fn {base, status, page, age, runs}, acc ->
        key = {base, status, page}
        Map.update(acc, key, {base, status, page, age, runs}, &keep_fresher_page(&1, {base, status, page, age, runs}))
      end)
      |> Map.values()

    %{runs: Enum.reduce(pages, %{}, &index_runs/2), active_listing_age_ms: active_listing_age(pages), refs: refs(entries, now_ms)}
  end

  defp keep_fresher_page({_base, _status, _page, previous_age, _runs}, {base, status, page, age, runs}) when age < previous_age,
    do: {base, status, page, age, runs}

  defp keep_fresher_page(previous, _candidate), do: previous

  defp page_runs(id, data) do
    case id |> to_string() |> String.split(":") |> Enum.reverse() do
      ["age-index", page, status | base] when is_list(data) ->
        [{Enum.reverse(base), status, page, data}]

      [page, status | base] when is_map(data) ->
        case Map.get(data, "workflow_runs") do
          runs when is_list(runs) -> [{Enum.reverse(base), status, page, runs}]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp index_runs({_base, status, _page, age, runs}, acc) do
    for %{"id" => id} <- runs, id = integer_value(id), is_integer(id), reduce: acc do
      acc -> Map.update(acc, id, %{status: status, age_ms: age}, &if(age < &1.age_ms, do: %{status: status, age_ms: age}, else: &1))
    end
  end

  # A run's absence means something only once every active status listing has been read.
  defp active_listing_age(pages) do
    ages_by_base =
      Enum.reduce(pages, %{}, fn
        {base, status, "0", age, _runs}, acc when status in @active_statuses ->
          Map.update(acc, base, %{status => age}, &Map.put(&1, status, age))

        _page, acc ->
          acc
      end)

    ages_by_base
    |> Map.values()
    |> Enum.filter(&(map_size(&1) == length(@active_statuses)))
    |> Enum.map(&(Map.values(&1) |> Enum.max()))
    |> case do
      [] -> nil
      ages -> Enum.min(ages)
    end
  end

  defp refs(entries, now_ms) do
    Enum.find_value(entries, fn {{_type, _owner, _repo, id}, entry} ->
      age = entry_age(entry, now_ms)
      if String.ends_with?(to_string(id), ":refs") and is_list(Map.get(entry, :data)) and is_integer(age), do: %{refs: Map.get(entry, :data), age_ms: age}
    end)
  end

  defp subject_ages(type, owner, repo, now_ms) do
    ResourceStore.list(type, owner, repo)
    |> Enum.reduce(%{}, fn {{^type, _owner, _repo, id}, entry}, ages ->
      with {number, ""} <- Integer.parse(to_string(id)),
           age when is_integer(age) <- entry_age(entry, now_ms) do
        Map.update(ages, number, age, &min(&1, age))
      else
        _ -> ages
      end
    end)
  end

  defp merge_group_ages(owner, repo, now_ms) do
    ResourceStore.list(:landing_merge_group_runs, owner, repo)
    |> Enum.reduce(%{}, &merge_group_page_ages(&1, &2, now_ms))
  end

  defp merge_group_page_ages({_key, entry}, ages, now_ms) do
    case {entry_age(entry, now_ms), page_run_data(Map.get(entry, :data))} do
      {age, runs} when is_integer(age) and is_list(runs) ->
        Enum.reduce(runs, ages, &merge_group_run_age(&1, &2, age))

      _ ->
        ages
    end
  end

  defp page_run_data(%{"workflow_runs" => runs}) when is_list(runs), do: runs
  defp page_run_data(runs) when is_list(runs), do: runs
  defp page_run_data(_), do: nil

  defp merge_group_run_age(run, ages, age) when is_map(run) do
    case integer_value(Map.get(run, "id")) do
      id when is_integer(id) -> Map.update(ages, id, age, &min(&1, age))
      _ -> ages
    end
  end

  defp merge_group_run_age(_ref, ages, _age), do: ages

  defp entry_age(entry, now_ms) do
    case Map.get(entry, :fetched_at_ms) do
      at when is_integer(at) and at <= now_ms -> now_ms - at
      _ -> nil
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer_value(_), do: nil
end
