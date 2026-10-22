defmodule Aiur.ExecutorSweep.CacheAges do
  @moduledoc false

  alias Aiur.GitHub.ResourceStore

  @spec for_repo(String.t(), String.t(), integer()) :: map()
  def for_repo(owner, repo, now_ms \\ System.system_time(:millisecond)) do
    pull_requests = subject_ages(:pull_request, owner, repo, now_ms)
    reviews = subject_ages(:pull_request_reviews, owner, repo, now_ms)

    %{
      pull_requests: Map.merge(pull_requests, reviews, fn _number, pr_age, review_age -> max(pr_age, review_age) end),
      merge_group_runs: merge_group_ages(owner, repo, now_ms)
    }
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
    case {entry_age(entry, now_ms), Map.get(entry, :data)} do
      {age, runs} when is_integer(age) and is_list(runs) ->
        Enum.reduce(runs, ages, &merge_group_run_age(&1, &2, age))

      _ ->
        ages
    end
  end

  defp merge_group_run_age(run, ages, age) do
    case integer_value(Map.get(run, "id")) do
      id when is_integer(id) -> Map.update(ages, id, age, &min(&1, age))
      _ -> ages
    end
  end

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
