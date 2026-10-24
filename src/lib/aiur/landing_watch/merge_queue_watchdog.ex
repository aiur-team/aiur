defmodule Aiur.LandingWatch.MergeQueueWatchdog do
  @moduledoc "Repairs queue entries that stay unmergeable despite a clean, ready PR."

  alias Aiur.Alerts

  alias Aiur.LandingWatch.{
    Journal,
    MergeQueueFailureEvidence,
    MergeQueueRecoveryAttempt,
    MergeQueueWatchdogEvidence,
    MergeQueueWatchdogRecovery
  }

  @threshold_ms 20 * 60_000
  @max_attempts 1

  @spec reconcile([map()], keyword()) :: :ok | {:error, term()}
  def reconcile(observations, opts) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      case reconcile_one(observation, now, opts) do
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end

  @spec after_reconcile(:ok | {:error, term()}, :ok | {:error, term()}, [map()], keyword()) ::
          :ok | {:error, term()}
  def after_reconcile(process_result, reconcile_result, observations, opts) do
    watchdog_result =
      Keyword.get(opts, :merge_queue_watchdog_fun, &__MODULE__.reconcile/2).(observations, opts)

    first_error([process_result, reconcile_result, watchdog_result])
  end

  defp first_error(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = error -> error
      nil -> :ok
    end
  end

  defp reconcile_one(
         %{
           number: number,
           head: head,
           merge_queue_entry: %{"id" => entry, "state" => _queue_state}
         } = observation,
         now,
         opts
       )
       when is_integer(number) and is_binary(head) and is_binary(entry) do
    if tracked_observation?(observation) do
      track_candidate(observation, now, opts)
    else
      # A healthy queue state breaks the UNMERGEABLE run; keep only the head's first sighting.
      case ensure_head_first_seen(number, head, now, opts, true) do
        {:ok, _first_seen} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp reconcile_one(%{number: number, head: head}, _now, opts)
       when is_integer(number) and is_binary(head),
       do: clear_first_seen(number, head, opts)

  defp reconcile_one(_, _, _), do: :ok

  defp reserve_first_seen(key, since, first_seen, opts) do
    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})

      existing =
        case Map.get(rows, key) do
          row when is_map(row) -> row
          since when is_integer(since) -> %{"since" => since, "attempts" => 0}
          _ -> %{"attempts" => 0}
        end

      first_seen =
        existing
        |> Map.get("first_seen_ms", Map.get(existing, "since"))
        |> earlier_since(first_seen)

      row =
        existing
        |> Map.put("since", earlier_since(Map.get(existing, "since"), since))
        |> Map.put("first_seen_ms", first_seen)

      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row)), row}
    end)
  end

  defp earlier_since(existing, candidate) when is_integer(existing), do: min(existing, candidate)
  defp earlier_since(_, candidate), do: candidate

  defp tracked_observation?(%{
         merge_state_status: status,
         mergeable: mergeable,
         merge_queue_entry: %{"state" => state}
       }),
       do:
         status in ["CLEAN", "UNKNOWN"] and mergeable in ["MERGEABLE", "UNKNOWN"] and
           state in ["UNMERGEABLE", "AWAITING_CHECKS"]

  defp tracked_observation?(_), do: false

  defp track_candidate(observation, now, opts) do
    queue_state = get_in(observation, [:merge_queue_entry, "state"])

    with {:ok, first_seen} <-
           ensure_head_first_seen(observation.number, observation.head, now, opts, false) do
      failed_since = failed_group_trigger_since(observation, first_seen, opts)
      candidate_since = candidate_since(queue_state, failed_since, now)

      case candidate_since do
        since when is_integer(since) ->
          reserve_candidate(observation, queue_state, since, first_seen, now, opts)

        _ ->
          :ok
      end
    end
  end

  defp ensure_head_first_seen(number, head, now, opts, reset_since?) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})

      rows =
        rows
        |> Enum.reject(fn
          {row_key, _row} when is_binary(row_key) ->
            String.starts_with?(row_key, "#{number}:") and row_key != key

          _ ->
            false
        end)
        |> Map.new()

      existing =
        case Map.get(rows, key) do
          row when is_map(row) -> row
          since when is_integer(since) -> %{"since" => since, "attempts" => 0}
          _ -> %{"attempts" => 0}
        end

      first_seen =
        case Map.get(existing, "first_seen_ms") do
          value when is_integer(value) -> value
          _ -> Map.get(existing, "since", now) || now
        end

      row = Map.put(existing, "first_seen_ms", first_seen)
      row = if reset_since?, do: Map.put(row, "since", nil), else: row

      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row)), first_seen}
    end)
  end

  defp reserve_candidate(observation, queue_state, since, first_seen, now, opts) do
    key = "#{observation.number}:#{observation.head}"

    with {:ok, row} <- reserve_first_seen(key, since, first_seen, opts),
         :ok <-
           if(queue_state == "UNMERGEABLE",
             do: maybe_repair(observation, row, now, opts),
             else: :ok
           ) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp candidate_since("UNMERGEABLE", failed_since, now) when is_integer(failed_since),
    do: min(failed_since, now)

  defp candidate_since("UNMERGEABLE", _failed_since, now), do: now

  defp candidate_since("AWAITING_CHECKS", failed_since, now) when is_integer(failed_since),
    do: min(failed_since, now)

  defp candidate_since(_, _, _), do: nil

  defp failed_group_trigger_since(observation, first_seen, opts) do
    runs = Keyword.get(opts, :completed_merge_group_runs, [])
    base = Keyword.get(opts, :base_branch, Aiur.Config.base_branch())

    MergeQueueFailureEvidence.failed_group_trigger_since_ms(
      observation.number,
      runs,
      base,
      first_seen
    )
  end

  defp maybe_repair(observation, row, now, opts) do
    cond do
      not is_integer(row_since(row)) or now - row_since(row) < @threshold_ms ->
        :ok

      row_attempts(row) >= @max_attempts ->
        maybe_give_up(observation, row, opts)

      not observation_eligible?(observation) ->
        :ok

      true ->
        evidence_opts = Keyword.put(opts, :unmergeable_since_ms, row_since(row))

        case classify_head_failure(observation, evidence_opts) do
          {:ok, failure} ->
            reserve_and_repair(observation, failure, now, opts)

          {:skip, reason} ->
            log_skip(observation, reason)
            :ok

          {:error, reason} ->
            log_skip(observation, reason)
            {:error, reason}
        end
    end
  end

  defp reserve_and_repair(observation, failure, now, opts) do
    case MergeQueueRecoveryAttempt.reserve(observation.number, observation.head, now, opts) do
      {:ok, :reserved} ->
        finish_reserved_repair(observation, failure, opts)

      {:skip, reason} ->
        log_skip(observation, reason)
        :ok

      {:error, reason} ->
        log_skip(observation, reason)
        {:error, reason}
    end
  end

  defp finish_reserved_repair(observation, failure, opts) do
    case repair(observation, opts) do
      :ok ->
        emit_attention(observation.number, observation.head, failure, opts)
        :ok

      {:error, {:attempt_commit_after_dequeue, _reason}} = error ->
        log_skip(observation, :attempt_commit_after_dequeue_failed)
        error

      {:skip, reason} ->
        MergeQueueRecoveryAttempt.release(observation.number, observation.head, opts)
        log_skip(observation, reason)
        :ok

      {:error, reason} = error ->
        MergeQueueRecoveryAttempt.release(observation.number, observation.head, opts)
        log_skip(observation, reason)
        error
    end
  end

  defp classify_head_failure(observation, opts) do
    case Keyword.get(opts, :head_failure_fun) do
      fun when is_function(fun, 2) ->
        case fun.(observation, opts) do
          {:ok, %{classification: kind} = evidence}
          when kind in [:infra, :inherited, :known_non_pr] ->
            {:ok, evidence}

          {:ok, %{classification: :pr_caused}} ->
            {:skip, :pr_caused_merge_group_failure}

          {:skip, _} = skip ->
            skip

          {:error, _} = error ->
            error

          _ ->
            {:skip, :merge_group_failure_not_proven_innocent}
        end

      _ ->
        classify_observed_head_failure(observation, opts)
    end
  end

  defp classify_observed_head_failure(observation, opts) do
    MergeQueueWatchdogEvidence.classify(observation, opts)
  end

  defp row_since(%{"since" => since}) when is_integer(since), do: since
  defp row_since(since) when is_integer(since), do: since
  defp row_since(_), do: 0

  defp row_attempts(%{"attempts" => attempts}) when is_integer(attempts), do: attempts
  defp row_attempts(_), do: 0

  defp observation_eligible?(observation),
    do:
      Map.get(observation, :draft?) == false and
        Map.get(observation, :review_decision) == "APPROVED" and
        is_nil(Map.get(observation, :auto_merge_request))

  defp maybe_give_up(observation, row, opts) do
    if row_attempts(row) == @max_attempts and not Map.get(row, "gave_up_alerted", false) do
      emit_gave_up(observation.number, observation.head, opts)
      mark_gave_up_alerted(observation.number, observation.head, opts)
      :ok
    else
      :ok
    end
  end

  defp clear_first_seen(number, _head, opts) do
    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})

      rows =
        Map.new(rows, fn
          pair -> clear_row_timer_for_number(pair, number)
        end)

      {:ok, Map.put(state, "unmergeable_queue_entries", rows)}
    end)
  end

  defp clear_row_timer(value) when is_map(value),
    do: value |> Map.put("since", nil) |> Map.put("first_seen_ms", nil)

  defp clear_row_timer(value) when is_integer(value),
    do: %{"since" => nil, "first_seen_ms" => nil, "attempts" => 0}

  defp clear_row_timer(value), do: value

  defp clear_row_timer_for_number({row_key, value}, number) when is_binary(row_key) do
    if String.starts_with?(row_key, "#{number}:") do
      {row_key, clear_row_timer(value)}
    else
      {row_key, value}
    end
  end

  defp clear_row_timer_for_number(pair, _number), do: pair

  defp mark_gave_up_alerted(number, head, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{}) |> Map.put("gave_up_alerted", true)
      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row))}
    end)
  end

  defp repair(observation, opts), do: MergeQueueWatchdogRecovery.repair(observation, opts)

  defp emit_attention(number, head, failure, opts) do
    tests = failure.failing_tests |> List.wrap() |> Enum.uniq()
    tests_text = if tests == [], do: "test names unavailable", else: Enum.join(tests, ", ")
    rebuilt = failure.rebuilt_groups

    message =
      "Merge queue entry for PR ##{number} stayed UNMERGEABLE or had repeated failed merge-group runs for over 20 minutes and was re-enqueued once. Failing tests: #{tests_text}. Rebuilt groups behind this queue head: #{rebuilt}."

    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovered",
      central: true,
      durable: true,
      needs_attention: true,
      message: message,
      reason: "stale_unmergeable_entry",
      head: head
    )
  end

  defp emit_gave_up(number, head, opts) do
    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovery_gave_up",
      central: true,
      durable: true,
      needs_attention: true,
      message: "Merge queue recovery for PR ##{number} reached #{@max_attempts} attempts; automatic retries stopped.",
      reason: "merge_queue_recovery_attempt_limit",
      head: head
    )
  end

  defp log_skip(observation, reason) do
    require Logger

    Logger.info("merge queue watchdog skipped PR ##{observation.number} head=#{observation.head} reason=#{inspect(reason)}")
  end
end
