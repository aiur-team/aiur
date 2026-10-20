defmodule Aiur.DecisionStore.Boot do
  @moduledoc false

  require Logger

  alias Aiur.Config
  alias Aiur.DecisionDispatch
  alias Aiur.DecisionDispatchTasks
  alias Aiur.DecisionEvent.Unrecognized
  alias Aiur.DecisionProjection
  alias Aiur.DecisionRevisionDispatch
  alias Aiur.DecisionStore
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Index
  alias Aiur.DecisionStore.ProjectionRecovery
  alias Aiur.DecisionStore.Requests
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.Events
  alias Aiur.ExecutorCommandAttention
  alias Aiur.ExecutorEvents
  alias Aiur.Journal
  alias Aiur.Signal

  @ndjson_filename "decisions.ndjson"
  @projection_filename "decisions.json"
  @default_dispatch_delay_ms 0
  @default_reconcile_delay_ms 250
  @default_retry_delays_ms [250, 1_000, 5_000]
  # A handed-off send with no outcome after this long has an unknown outcome
  # (for example, the daemon stopped mid-send). A withdrawal is still refused,
  # but the operator is told, because only they can check the agent (#2711).
  @handoff_unknown_after_ms 60_000

  @spec validate_start_options(term()) :: term()
  def validate_start_options(opts) do
    case Keyword.fetch(opts, :state_dir) do
      :error -> validate_missing_state_dir(Keyword.get(opts, :name))
      {:ok, state_dir} -> validate_state_dir(state_dir)
    end
  end

  defp validate_missing_state_dir(DecisionStore), do: :ok
  defp validate_missing_state_dir(nil), do: {:error, :unnamed_store_requires_state_dir}
  defp validate_missing_state_dir(_name), do: {:error, :non_singleton_store_requires_state_dir}

  defp validate_state_dir(state_dir) when is_binary(state_dir) and state_dir != "", do: :ok
  defp validate_state_dir(_state_dir), do: {:error, :invalid_state_dir}

  @spec state_dir(term()) :: term()
  def state_dir(opts) do
    case Keyword.fetch(opts, :state_dir) do
      {:ok, dir} -> {:ok, dir}
      :error -> Config.Paths.decision_state_dir()
    end
  end

  @spec configure_dispatch(term(), term()) :: term()
  def configure_dispatch(state, opts) do
    revision_projector =
      Keyword.get(opts, :revision_follow_up_projector, &DecisionRevisionDispatch.project_follow_up/2)

    revision_resolver =
      Keyword.get(opts, :revision_follow_up_resolver, &DecisionRevisionDispatch.resolve_follow_up/2)

    state =
      Map.merge(state, %{
        file_ops: Keyword.get(opts, :file_ops, :file),
        follow_up_append_retries: %{},
        held_journal_work: [],
        dispatcher: Keyword.get(opts, :dispatcher, &DecisionDispatch.dispatch/2),
        decision_dispatch_tasks: Keyword.get(opts, :decision_dispatch_tasks, DecisionDispatchTasks),
        decision_dispatch_monitor_pid: nil,
        decision_dispatch_monitor_ref: nil,
        decision_dispatch_monitor_timer: nil,
        decision_dispatch_monitor_reconcile?: false,
        dispatch_delay_ms: Keyword.get(opts, :dispatch_delay_ms, @default_dispatch_delay_ms),
        reconcile_delay_ms: Keyword.get(opts, :reconcile_delay_ms, @default_reconcile_delay_ms),
        retry_delays_ms: Keyword.get(opts, :retry_delays_ms, @default_retry_delays_ms),
        handoff_unknown_after_ms: Keyword.get(opts, :handoff_unknown_after_ms, @handoff_unknown_after_ms),
        terminal_ticket_resolver: Keyword.get(opts, :terminal_ticket_resolver, &FailureAttention.default_terminal_ticket_resolver/1),
        dispatch_scheduler: Keyword.get(opts, :dispatch_scheduler, &Process.send_after/3),
        revision_follow_up_projector: revision_projector,
        revision_follow_up_resolver: revision_resolver,
        event_id_reserver: Keyword.get(opts, :event_id_reserver, &Events.reserve_durable_id/0),
        executor_attention_opener: Keyword.get(opts, :executor_attention_opener, &ExecutorCommandAttention.open/3),
        executor_request_boot_reconciler: Keyword.get(opts, :executor_request_boot_reconciler, &ExecutorEvents.reconcile_requested/1),
        executor_request_publisher: Keyword.get(opts, :executor_request_publisher, &ExecutorEvents.publish_requested/1),
        executor_request_reconciler: Keyword.get(opts, :executor_request_reconciler, &ExecutorEvents.ensure_requested/1),
        dispatching: %{},
        retry_counts: %{},
        projecting_revision_follow_ups: MapSet.new(),
        resolving_revision_follow_ups: MapSet.new(),
        append_retry_counts: %{},
        lifecycle_append_failures: MapSet.new(),
        failure_attention_reprojection_pending?: false,
        failure_attention_reprojection_waiters: []
      })

    Dispatch.monitor_decision_dispatch_tasks(state)
  end

  @spec handle_continue(term(), term()) :: term()
  def handle_continue(:schedule_reconciliation, state) do
    state =
      if state.writable? and state.health == :writable do
        Requests.reconcile_requested_executor_notifications(state)
        Requests.reconcile_deferred_executor_notifications(state)
        state = FailureAttention.schedule_failure_attention_reprojection(state)
        schedule_closed_expired_blocker_mooting(state)

        Dispatch.schedule_dispatch_work(
          state,
          {:reconcile_dispatches, Dispatch.dispatch_fences(state)},
          state.reconcile_delay_ms
        )

        state
      else
        state
      end

    {:noreply, state}
  end

  # Old expired blocking Commands remain in durable history and visible query
  # results. Retire only those whose ticket is confirmed terminal, so the open
  # banner does not count questions nobody can act on. The tracker read is
  # batched and detached; failures fail open and leave the records answerable.
  defp schedule_closed_expired_blocker_mooting(state) do
    decisions = Enum.filter(Map.values(state.current), &expired_blocking_unanswered?/1)

    if decisions != [] do
      store = self()
      resolver = state.terminal_ticket_resolver
      moot_fun = &DecisionStore.moot/4

      Task.start(fn ->
        moot_closed_expired_blockers(store, resolver, moot_fun, decisions)
      end)
    end
  end

  defp moot_closed_expired_blockers(store, resolver, moot_fun, decisions) do
    identifiers = decisions |> Enum.map(& &1.ticket.identifier) |> Enum.uniq()

    terminal =
      case resolver.(identifiers) do
        {:ok, %MapSet{} = ids} -> ids
        {:ok, ids} when is_list(ids) -> MapSet.new(ids)
        {:error, reason} -> raise "terminal ticket lookup failed: #{inspect(reason)}"
      end

    Enum.each(decisions, fn decision ->
      if MapSet.member?(terminal, decision.ticket.identifier) do
        moot_fun.(decision.decision_id, %{"reason_class" => "ticket_closed"}, [actor: %{kind: :system, id: "decision-store"}], store)
      end
    end)
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=closed_expired_blocker_reconciliation_failed error=#{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("aiur_decision_store phase=closed_expired_blocker_reconciliation_failed kind=#{kind} reason=#{inspect(reason)}")
  end

  defp expired_blocking_unanswered?(%{decision_status: :expired, blocking: true, answer: nil}), do: true
  defp expired_blocking_unanswered?(_decision), do: false

  @spec boot(term(), term()) :: term()
  def boot(dir, filesystem_sync_fun) do
    ndjson_path = Path.join(dir, @ndjson_filename)
    projection_path = Path.join(dir, @projection_filename)

    case Journal.prepare(dir, ndjson_path, filesystem_sync_fun) do
      :ok -> replay_and_project(ndjson_path, projection_path)
      {:error, reason} -> unavailable_state(ndjson_path, {:directory_unavailable, reason})
    end
  end

  defp replay_and_project(ndjson_path, projection_path) do
    case Journal.replay(ndjson_path, &DecisionProjection.decode_record/1) do
      {:ok, records, corruption} ->
        {%{current: current, history: history, audit_history: audit_history}, transition_corruption} =
          DecisionProjection.reduce_checked(records)

        %{
          ndjson_path: ndjson_path,
          projection_path: projection_path,
          current: current,
          decision_index: Index.build_decision_index(current),
          retained_index: RetainedSnapshot.build_index(current, history),
          # The store keeps histories newest-first so every accepted append is
          # O(1). The public history call reverses them back to audit order.
          history: Index.reverse_histories(history),
          audit_history: audit_history,
          # Unrecognized records are retained on disk and in `records`, but
          # they are not shown: this binary cannot render an event whose shape
          # it does not know, and guessing would be worse than omitting.
          recent_audit:
            records
            |> Enum.reject(&match?(%Unrecognized{}, &1))
            |> Enum.reverse()
            |> Enum.take(Audit.recent_limit()),
          writable?: true,
          health: :writable
        }
        |> ProjectionRecovery.initialize(records)
        |> report_unrecognized_records(records, ndjson_path)
        |> apply_corruption(transition_corruption || corruption)

      {:error, reason} ->
        unavailable_state(ndjson_path, {:replay_failed, reason})
    end
  end

  # A newer binary wrote event types this one cannot interpret. That is version
  # skew, not damage, so the store stays writable and keeps answering Commands
  # — but the operator is told, because their projection is silently missing
  # whatever those events said. Deliberately not `needs_attention`: the fix is
  # to roll forward again, and nothing is lost by waiting.
  defp report_unrecognized_records(state, records, path) do
    types =
      records
      |> Enum.filter(&match?(%Unrecognized{}, &1))
      |> Enum.map(& &1.event_type)
      |> Enum.uniq()
      |> Enum.sort()

    if types == [] do
      state
    else
      listed = Enum.join(types, ", ")

      Logger.warning(
        "aiur_decision_store phase=unrecognized_event_types path=#{path} types=#{listed} " <>
          "action=retained_and_skipped"
      )

      _ =
        Signal.agent_alert(
          "decision_store.unrecognized_event_types",
          "DecisionStore replayed audit records this build does not understand (#{listed}) at #{path}. " <>
            "They are retained on disk and skipped; the store stays writable. " <>
            "This build is older than the one that wrote them — roll forward to project them.",
          needs_attention: false,
          severity: "warning"
        )

      state
    end
  end

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    inspected_reason = inspect(reason)
    path = state.ndjson_path

    Logger.error("aiur_decision_store phase=corruption path=#{path} line=#{line} reason=#{inspected_reason}")

    _ =
      Signal.agent_alert(
        "decision_store.corrupted",
        "DecisionStore audit log corrupt at #{path} line #{line} " <>
          "(#{inspected_reason}); store is read-only.",
        needs_attention: true
      )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  @spec unavailable_state(term(), term()) :: term()
  def unavailable_state(ndjson_path, reason) do
    Logger.error("aiur_decision_store phase=unavailable reason=#{inspect(reason)}")

    %{
      ndjson_path: ndjson_path,
      projection_path: nil,
      current: %{},
      decision_index: :gb_sets.empty(),
      retained_index: RetainedSnapshot.build_index(%{}),
      history: %{},
      audit_history: %{},
      recent_audit: [],
      writable?: false,
      health: {:unavailable, reason},
      pending_notifications: [],
      last_event_id: nil,
      projection_retry: nil,
      projection: :healthy,
      failure_attention_reprojection_pending?: false,
      failure_attention_reprojection_waiters: []
    }
  end
end
