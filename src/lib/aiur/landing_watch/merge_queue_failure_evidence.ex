defmodule Aiur.LandingWatch.MergeQueueFailureEvidence do
  @moduledoc false

  @spec run_pr_numbers(binary() | nil, String.t()) :: [pos_integer()]
  def run_pr_numbers(branch, base) when is_binary(branch) do
    prefix = "gh-readonly-queue/#{base}/"

    if String.starts_with?(branch, prefix) do
      Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
    else
      []
    end
  end

  def run_pr_numbers(_, _), do: []

  @spec failed_group_trigger_since_ms(pos_integer(), [map()], String.t(), integer()) ::
          integer() | nil
  def failed_group_trigger_since_ms(number, runs, base, first_seen_ms) do
    runs
    |> Enum.filter(fn run ->
      run["event"] == "merge_group" and
        run["conclusion"] in ["failure", "cancelled", "timed_out", "startup_failure"] and
        is_integer(run["id"]) and is_integer(run_time_ms(run)) and
        run_time_ms(run) >= first_seen_ms and
        number in run_pr_numbers(run["head_branch"], base)
    end)
    |> Enum.map(&run_time_ms/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.at(1)
  end

  @spec rebuilt_group_count([map()], map(), [map()], String.t(), integer()) :: non_neg_integer()
  def rebuilt_group_count(runs, head_observation, observations, base, since_ms) do
    head_position = get_in(head_observation, [:merge_queue_entry, "position"])
    since_time = DateTime.from_unix!(since_ms, :millisecond)

    if is_integer(head_position) do
      behind =
        observations
        |> Enum.filter(fn observation ->
          position = get_in(observation, [:merge_queue_entry, "position"])
          is_integer(position) and position > head_position and is_integer(observation[:number])
        end)
        |> Enum.map(& &1.number)
        |> MapSet.new()

      Enum.count(runs, fn run ->
        run["event"] == "merge_group" and
          DateTime.compare(parse_time(run["created_at"]), since_time) in [:eq, :gt] and
          Enum.any?(run_pr_numbers(run["head_branch"], base), &MapSet.member?(behind, &1))
      end)
    else
      0
    end
  end

  @spec test_names(String.t()) :: [String.t()]
  def test_names(log) do
    Regex.scan(~r/((?:test\/)?[\w.\/-]+_test\.exs(?::\d+)?|test [^\r\n]+)/, log, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> DateTime.from_unix!(0)
    end
  end

  defp parse_time(_), do: DateTime.from_unix!(0)

  defp run_time_ms(run) do
    case DateTime.from_iso8601(run["run_started_at"] || run["created_at"] || "") do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end
end
