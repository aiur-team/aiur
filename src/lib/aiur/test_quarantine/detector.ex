defmodule Aiur.TestQuarantine.Detector do
  @moduledoc "Finds repeated failures in independent pull requests within a bounded window."

  @window_ms 24 * 60 * 60 * 1_000

  @spec repeated([map()], integer(), (pos_integer() -> {:ok, [String.t()]} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def repeated(failures, now_ms, changed_paths_fun) when is_list(failures) and is_integer(now_ms) and is_function(changed_paths_fun, 1) do
    failures
    |> observations_by_pr(changed_paths_fun, now_ms)
    |> case do
      {:ok, rows} -> {:ok, rows |> Enum.group_by(& &1.identity) |> Enum.flat_map(&qualifying_identity(&1, now_ms))}
      error -> error
    end
  end

  def repeated(_, _, _), do: {:ok, []}

  defp observations_by_pr(failures, changed_paths_fun, now) do
    failures
    |> Enum.filter(&valid_observation?(&1, now))
    |> Enum.group_by(& &1.pr)
    |> Enum.reduce_while({:ok, []}, fn {pr, observations}, {:ok, acc} ->
      case changed_paths_fun.(pr) do
        {:ok, paths} when is_list(paths) -> {:cont, {:ok, acc ++ Enum.reject(observations, &(&1.path in paths))}}
        {:error, reason} -> {:halt, {:error, {:changed_paths_unavailable, pr, reason}}}
        _ -> {:halt, {:error, {:invalid_changed_paths, pr}}}
      end
    end)
  end

  defp valid_observation?(%{identity: id, pr: pr, run_url: url, at_ms: at, path: path, group_prs: group_prs}, now) do
    valid_identity?(id) and valid_pr?(pr) and valid_run?(url) and valid_time?(at, now) and
      valid_path?(path) and valid_group_prs?(group_prs, pr)
  end

  defp valid_observation?(_, _), do: false

  defp valid_identity?(id), do: is_binary(id) and id != ""
  defp valid_pr?(pr), do: is_integer(pr) and pr > 0
  defp valid_run?(url), do: is_binary(url) and url != ""
  defp valid_time?(at, now), do: is_integer(at) and at <= now and now - at <= @window_ms
  defp valid_path?(path), do: is_binary(path) and path != ""
  defp valid_group_prs?(prs, pr), do: is_list(prs) and pr in prs and Enum.all?(prs, &valid_pr?/1)

  defp qualifying_identity({identity, rows}, now) do
    rows = Enum.uniq_by(rows, &{&1.pr, &1.run_url})
    if independent_failures_in_window?(rows, now), do: [%{identity: identity, observations: rows}], else: []
  end

  defp independent_failures_in_window?(rows, now) do
    within_window = Enum.filter(rows, &(now - &1.at_ms <= @window_ms))

    Enum.any?(within_window, fn left ->
      Enum.any?(within_window, fn right ->
        left.pr != right.pr and left.run_url != right.run_url and
          MapSet.disjoint?(MapSet.new(group_prs(left)), MapSet.new(group_prs(right)))
      end)
    end)
  end

  defp group_prs(%{group_prs: prs}) when is_list(prs), do: prs
  defp group_prs(%{pr: pr}), do: [pr]
end
