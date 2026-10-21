defmodule Aiur.LandingWatch.MergeGroups do
  @moduledoc "Reconciles live merge-queue entries and cancels runs for groups that no longer exist."

  require Logger

  alias Aiur.GitHub.{CIRecovery, Transport}

  alias Aiur.LandingWatch.{
    MergeGroupFailureProcessor,
    MergeGroupQuarantine,
    MergeGroupRunFetcher,
    Observer
  }

  @spec cancel_stale([map()], keyword()) :: :ok | {:error, term()}
  def cancel_stale(observations, opts \\ [])

  def cancel_stale(observations, opts) when is_list(observations) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, runs} <- MergeGroupRunFetcher.active_runs(owner, repo, base, token, opts),
         {:ok, completed} <- MergeGroupRunFetcher.completed_runs(owner, repo, base, token, opts),
         {:ok, fresh_observations} <- live_observations(observations, opts) do
      # Quarantine runs first and on its own: a failure-routing error must not stop it, and
      # the failure router then requeues, rather than reworks, PRs a quarantined test dropped.
      quarantine =
        MergeGroupQuarantine.process_completed(completed, fresh_observations, base, opts)

      routing_opts =
        Keyword.put(opts, :quarantined_run_ids, MergeGroupQuarantine.quarantined_run_ids(opts))

      with :ok <-
             MergeGroupFailureProcessor.process_completed(
               completed,
               fresh_observations,
               base,
               routing_opts
             ),
           :ok <- quarantine,
           {:ok, reconciled_observations} <- live_observations(fresh_observations, opts) do
        live =
          Map.new(
            Enum.map(reconciled_observations, &live_entry(&1, base))
            |> Enum.reject(&is_nil/1)
          )

        group_heads =
          live
          |> Map.values()
          |> Enum.map(& &1.group_head)
          |> Enum.filter(&is_binary/1)
          |> MapSet.new()

        stale =
          Enum.flat_map(runs, fn run ->
            cond do
              stale?(run, base, live) ->
                [{run, "queue_entry_not_live"}]

              stale_group_head?(run, base, live, group_heads) ->
                [{run, "group_head_not_live"}]

              true ->
                []
            end
          end)

        cancel_runs(stale, opts)
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
            group_head: get_in(entry, ["headCommit", "oid"]),
            group_head_committed_at: get_in(entry, ["headCommit", "committedDate"])
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
      numbers = run_pr_numbers(branch, prefix)

      numbers != [] and
        Enum.any?(numbers, &(not current_entry?(Map.get(live, &1), run)))
    else
      false
    end
  end

  defp stale?(_run, _base, _live), do: false

  defp run_pr_numbers(branch, prefix) do
    branch
    |> String.replace_prefix(prefix, "")
    |> then(&Regex.scan(~r/(?:^|-)pr-(\d+)-/, "pr-" <> &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
  end

  # A queue rebuild keeps each PR queued but gives it a new group head, so a run
  # whose head SHA no live entry carries holds a runner for a dead group (#4864).
  # With no group heads observed there is nothing to compare, so cancel nothing.
  defp stale_group_head?(
         %{
           "id" => id,
           "event" => "merge_group",
           "status" => status,
           "head_sha" => sha,
           "created_at" => created_at
         } = run,
         base,
         live,
         group_heads
       )
       when is_integer(id) and is_binary(sha) and
              status in ["queued", "in_progress", "waiting", "requested"],
       do:
         not MapSet.member?(group_heads, sha) and
           run_precedes_live_group?(run, base, live, created_at)

  defp stale_group_head?(_run, _base, _live, _group_heads), do: false

  defp run_precedes_live_group?(run, base, live, created_at) do
    prefix = "gh-readonly-queue/#{base}/pr-"
    numbers = run_pr_numbers(run["head_branch"], prefix)

    is_binary(created_at) and numbers != [] and
      Enum.any?(numbers, fn number ->
        case Map.get(live, number) do
          %{group_head_committed_at: group_created_at} when is_binary(group_created_at) ->
            timestamp_before?(created_at, group_created_at)

          _ ->
            false
        end
      end)
  end

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

  defp timestamp_before?(left, right) do
    with {:ok, left_time, _} <- DateTime.from_iso8601(left),
         {:ok, right_time, _} <- DateTime.from_iso8601(right) do
      DateTime.compare(left_time, right_time) == :lt
    else
      _ -> false
    end
  end

  # A failed cancel is logged and skipped so one bad run cannot block the rest or fail the poll.
  defp cancel_runs(runs, opts) do
    opts = Keyword.put(opts, :caller, "landing_watch_stale_merge_group_cancel")

    Enum.each(runs, fn {run, reason} ->
      cancel_run(run, reason, opts)
    end)
  end

  defp cancel_run(run, reason, opts) do
    case Keyword.get(opts, :cancel_fun, &CIRecovery.cancel/2).(run["id"], opts) do
      :ok ->
        Logger.info("landing watcher cancelled merge-group run id=#{run["id"]} head=#{run["head_sha"]} reason=#{reason}")

      {:error, failure} ->
        Logger.warning("landing watcher could not cancel merge-group run id=#{run["id"]} head=#{run["head_sha"]} reason=#{reason}: #{inspect(failure)}")
    end
  end
end
