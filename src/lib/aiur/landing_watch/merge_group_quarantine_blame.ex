defmodule Aiur.LandingWatch.MergeGroupQuarantineBlame do
  @moduledoc false

  require Logger

  alias Aiur.LandingWatch.{MergeFailureClassifier, MergeFailureOptions, MergeGroupFailureEvidence, QuarantineEvidence}

  # Blame is advisory: when its evidence cannot be read, the failure takes the ordinary flake path.
  @spec pr_caused_failure?(map(), [integer()], [map()], String.t(), keyword()) :: boolean()
  def pr_caused_failure?(run, prs, jobs, base, opts) do
    options = MergeFailureOptions.build(run, prs, jobs, opts, &MergeGroupFailureEvidence.job_log/2)

    case MergeFailureClassifier.classify(run, jobs, [], options) do
      {:ok, {:pr_caused, %{log: log}}} ->
        blamed_test_path?(log, prs, base, options)

      {:ok, _} ->
        false

      {:error, reason} ->
        Logger.warning("merge-group blame unavailable; treating failure as unblamed run=#{run["id"]} reason=#{inspect(reason)}")
        false
    end
  end

  defp blamed_test_path?(log, prs, base, opts) do
    paths = MergeGroupFailureEvidence.test_paths(log)

    Enum.any?(paths, &Enum.any?(prs, fn pr -> path_touched_by_pr?(&1, pr, opts) end)) or
      Enum.any?(paths, &(single_test_area_change?(&1, prs, opts) and green_on_main?(&1, base, opts)))
  end

  # Read main's recent failures only when the area heuristic needs them; unreadable means not proven green.
  defp green_on_main?(path, base, opts) do
    case MergeGroupFailureEvidence.recent_main_paths(base, opts) do
      {:ok, main_failures} -> path not in main_failures
      {:error, _reason} -> false
    end
  end

  defp single_test_area_change?(test_path, prs, opts) do
    Enum.count(prs, fn pr ->
      case get_in(opts, [:changed_paths_by_pr, pr]) do
        paths when is_list(paths) -> test_area_changed?(test_path, paths)
        _ -> false
      end
    end) == 1
  end

  defp test_area_changed?("src/test/" <> rest, changed_paths) do
    area = rest |> Path.dirname() |> then(&Path.join("src/lib", &1))
    Enum.any?(changed_paths, &(is_binary(&1) and String.starts_with?(&1, area <> "/")))
  end

  defp test_area_changed?(_test_path, _changed_paths), do: false

  defp path_touched_by_pr?(path, pr, opts) do
    case get_in(opts, [:changed_paths_by_pr, pr]) do
      paths when is_list(paths) -> QuarantineEvidence.touched?(path, paths)
      _ -> false
    end
  end
end
