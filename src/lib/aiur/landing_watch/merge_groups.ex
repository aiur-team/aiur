defmodule Aiur.LandingWatch.MergeGroups do
  @moduledoc "Cancels active merge-group runs that no longer belong to the live queue."

  require Logger

  alias Aiur.GitHub.{CIRecovery, Transport}
  alias Aiur.LandingWatch.{MergeGroupFailureProcessor, MergeGroupQuarantine, MergeGroupRunFetcher, Observer}

  @spec cancel_stale([map()], keyword()) :: :ok | {:error, term()}
  def cancel_stale(observations, opts \\ [])

  def cancel_stale(observations, opts) when is_list(observations) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, runs} <- MergeGroupRunFetcher.active_runs(owner, repo, base, token, opts),
         {:ok, completed} <- MergeGroupRunFetcher.completed_runs(owner, repo, base, token, opts),
         {:ok, fresh_observations} <- live_observations(observations, opts) do
      with :ok <- MergeGroupFailureProcessor.process_completed(completed, fresh_observations, base, opts),
           :ok <- MergeGroupQuarantine.process_completed(completed, base, opts),
           {:ok, reconciled_observations} <- live_observations(fresh_observations, opts) do
        live =
          Map.new(
            Enum.map(reconciled_observations, &live_entry(&1, base))
            |> Enum.reject(&is_nil/1)
          )

        group_heads = live |> Map.values() |> Enum.map(& &1.group_head) |> Enum.filter(&is_binary/1) |> MapSet.new()
        cancel_runs(Enum.filter(runs, &(stale?(&1, base, live) or stale_group_head?(&1, group_heads))), opts)
      end
    end
  end

  def cancel_stale(_, _), do: {:error, :invalid_queue_observations}

  defp live_observations(fallback, opts) do
    case Keyword.get(opts, :live_observations_fun, &Observer.refresh_queue/2).(fallback, opts) do
      {:ok, observations} when is_list(observations) -> {:ok, observations}
      {:error, _} = error -> error
      _ -> {:error, :invalid_live_queue_observations}
    end
  end

  defp live_entry(%{base: base, number: number, merge_queue_entry: entry} = observation, base)
       when is_integer(number) and is_map(entry),
       do:
         {number,
          %{
            head: Map.get(observation, :head),
            committed_at: Map.get(observation, :head_committed_at),
            queue_head: get_in(entry, ["pullRequest", "headRefOid"]),
            group_head: get_in(entry, ["headCommit", "oid"])
          }}

  defp live_entry(_observation, _base), do: nil

  defp stale?(
         %{"id" => id, "event" => "merge_group", "status" => status, "head_branch" => branch} =
           run,
         base,
         live
       )
       when is_integer(id) and status in ["queued", "in_progress", "waiting", "requested"] and
              is_binary(branch) do
    prefix = "gh-readonly-queue/#{base}/pr-"

    if String.starts_with?(branch, prefix) do
      branch
      |> then(&Regex.scan(~r/pr-(\d+)-/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Enum.any?(&(not current_entry?(Map.get(live, &1), run)))
    else
      false
    end
  end

  defp stale?(_run, _base, _live), do: false

  # A queue rebuild keeps each PR queued but gives it a new group head, so a run
  # whose head SHA no live entry carries holds a runner for a dead group (#4864).
  # With no group heads observed there is nothing to compare, so cancel nothing.
  defp stale_group_head?(%{"id" => id, "event" => "merge_group", "status" => status, "head_sha" => sha}, group_heads)
       when is_integer(id) and is_binary(sha) and status in ["queued", "in_progress", "waiting", "requested"],
       do: MapSet.size(group_heads) > 0 and not MapSet.member?(group_heads, sha)

  defp stale_group_head?(_run, _group_heads), do: false

  defp current_entry?(nil, _run), do: false

  defp current_entry?(%{head: head, committed_at: committed_at, queue_head: queue_head}, %{
         "created_at" => created_at
       })
       when is_binary(head) and is_binary(committed_at) and is_binary(queue_head) and
              is_binary(created_at) do
    queue_head == head and timestamp_at_or_after?(created_at, committed_at)
  end

  defp current_entry?(_entry, _run), do: true

  defp timestamp_at_or_after?(created_at, committed_at) do
    with {:ok, run_time, _} <- DateTime.from_iso8601(created_at),
         {:ok, head_time, _} <- DateTime.from_iso8601(committed_at) do
      DateTime.compare(run_time, head_time) in [:eq, :gt]
    else
      _ -> false
    end
  end

  # A failed cancel is logged and skipped so one bad run cannot block the rest or fail the poll.
  defp cancel_runs(runs, opts) do
    opts = Keyword.put(opts, :caller, "landing_watch_stale_merge_group_cancel")
    Enum.each(runs, &cancel_run(&1, opts))
  end

  defp cancel_run(run, opts) do
    case Keyword.get(opts, :cancel_fun, &CIRecovery.cancel/2).(run["id"], opts) do
      :ok ->
        Logger.info("landing watcher cancelled stale merge-group run #{run["id"]} head=#{run["head_sha"]} branch=#{run["head_branch"]}")

      {:error, reason} ->
        Logger.warning("landing watcher could not cancel stale merge-group run #{run["id"]}: #{inspect(reason)}")
    end
  end
end
