defmodule Aiur.Orchestrator.Dispatcher.Selection do
  @moduledoc """
  Selects candidates for available slots. It owns the batch continuation and
  records the outcome at the worker start so skipped reasons reach the snapshot.
  """

  require Logger

  import Aiur.Orchestrator.PauseGuard, only: [effective_paused?: 1]

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DependencyGate, DispatchBatch, DispatchCandidates, DispatchPolicy, MachineGrant, Slots, State, StatusReport, TrackerTasks}
  alias Aiur.Orchestrator.Dispatcher.{Candidates, Launch}

  @recent_selections 10

  @spec choose(State.t(), [Issue.t()], keyword()) :: State.t()
  def choose(state, issues, opts) do
    active = DispatchPolicy.active_state_set()
    terminal = DispatchPolicy.terminal_state_set()
    state = %{state | dispatch_declines: Map.take(state.dispatch_declines, Enum.map(issues, & &1.id))}
    {candidates, held, deferred} = DispatchCandidates.partition(issues, terminal, Map.values(state.last_polled_issues))
    state = Candidates.hold_cached_dependencies(state, held, active, terminal)

    held_reasons = for issue <- held, do: {issue, Map.get(state.dispatch_declines, issue.id, :dependency)}
    skipped = Map.new(held_reasons ++ deferred, fn {issue, reason} -> {issue.id, {issue, reason}} end)
    batch = %{active: active, terminal: terminal, initial?: state.initial_dispatch_cycle == true, index: 0, skipped: skipped, retry: []}
    choose_in_order(state, candidates, opts, batch)
  end

  @doc "Checks whether recovery would overtake a higher-priority dispatch attempt."
  @spec recovery_yields?(State.t(), Issue.t()) :: boolean()
  def recovery_yields?(state, issue) do
    higher_pending_key(state, issue) != nil or
      (TrackerTasks.running?(state, :dispatch_poll) and
         Enum.any?(state.last_polled_issues, fn {_id, waiting} ->
           higher_priority?(waiting, issue) and DispatchPolicy.should_dispatch_issue?(DependencyGate.cached_issue(waiting), state)
         end))
  end

  @doc "Applies a validated batch candidate after any higher-priority attempt that arrived during validation."
  @spec apply_in_priority_order(State.t(), Issue.t(), keyword(), (State.t(), keyword() -> State.t())) :: State.t()
  def apply_in_priority_order(state, issue, opts, apply) do
    with skipped when is_map(skipped) <- opts[:dispatch_skips],
         {_, _} = key <- higher_pending_key(state, issue) do
      await_higher_attempt(state, key, fn current, waiting, reason ->
        apply_in_priority_order(current, issue, Keyword.put(opts, :dispatch_skips, put_skip(skipped, waiting, reason)), apply)
      end)
    else
      _ -> apply.(state, opts)
    end
  end

  defp higher_pending_key(state, issue) do
    Enum.find_value(state.tracker_tasks, fn
      {_ref, %{key: {kind, id} = key}} when kind in [:dispatch, :rework_claim] ->
        pending = Map.get(state.last_polled_issues, id)
        if pending && higher_priority?(pending, issue), do: key

      _other ->
        nil
    end)
  end

  defp choose_in_order(%State{} = state, _issues, opts, _batch) when effective_paused?(state),
    do: DispatchBatch.finish(state, opts, nil)

  defp choose_in_order(state, [], opts, _batch), do: DispatchBatch.finish(state, opts, nil)

  defp choose_in_order(state, [issue | rest] = remaining, opts, batch) do
    DispatchBatch.advance(state, remaining, opts, fn -> choose_ready_issue(state, issue, rest, opts, batch) end, fn current, resume_opts ->
      choose_in_order(current, remaining, resume_opts, batch)
    end)
  end

  defp choose_ready_issue(state, issue, rest, opts, batch) do
    case higher_pending_key(state, issue) do
      nil ->
        attempt(state, issue, rest, opts, batch)

      key ->
        await_higher_attempt(state, key, fn current, pending, reason ->
          choose_in_order(current, [issue | rest], opts, note_skip(batch, pending, reason))
        end)
    end
  end

  defp await_higher_attempt(state, {_kind, id} = key, continue) do
    pending = Map.fetch!(state.last_polled_issues, id)

    TrackerTasks.retain_completion(state, key, fn current, _result ->
      reason = unless Map.has_key?(current.running, id), do: Map.get(current.dispatch_declines, id)
      continue.(current, pending, reason)
    end)
  end

  defp attempt(state, issue, rest, opts, batch) do
    {state, decision} = Launch.recover_orphaned_claim(state, issue, batch.active, batch.terminal)

    case decision do
      :dispatch ->
        was_claimed? = MapSet.member?(state.claimed, issue.id)
        completion = &after_validation(&1, issue, rest, opts, batch, was_claimed?)
        dispatch_opts = Keyword.merge(opts, dispatch_result_fun: completion, dispatch_skips: batch.skipped)
        Candidates.start_dispatch_validation(state, issue, nil, nil, dispatch_opts)

      {:skip, reason} ->
        next = Candidates.maybe_emit_dispatch_decline(state, issue, reason)
        choose_in_order(next, rest, opts, note_skip(batch, issue, reason))
    end
  end

  defp after_validation(state, issue, rest, opts, batch, was_claimed?) do
    key = {:rework_claim, issue.id}

    if TrackerTasks.running?(state, key) do
      TrackerTasks.retain_completion(state, key, fn current, _result -> after_attempt(current, issue, rest, opts, batch, was_claimed?) end)
    else
      after_attempt(state, issue, rest, opts, batch, was_claimed?)
    end
  end

  defp after_attempt(state, issue, rest, opts, batch, was_claimed?) do
    if Map.has_key?(state.running, issue.id) do
      batch = if was_claimed?, do: batch, else: schedule_startup_todo_alert(state, issue, batch)
      {retry, skipped} = next_slot(state, batch)
      choose_in_order(state, retry ++ rest, opts, %{batch | skipped: Map.delete(skipped, issue.id), retry: []})
    else
      reason = Map.get(state.dispatch_declines, issue.id) || get_in(state.retry_attempts, [issue.id, :delay_type]) || :unknown
      choose_in_order(state, rest, opts, note_skip(batch, issue, reason))
    end
  end

  defp note_skip(batch, _issue, nil), do: batch
  defp note_skip(batch, issue, :already_running), do: %{batch | skipped: Map.delete(batch.skipped, issue.id)}

  defp note_skip(batch, issue, reason) do
    retry = if retry_next_slot?(reason), do: [issue | batch.retry], else: batch.retry
    %{batch | skipped: put_skip(batch.skipped, issue, reason), retry: retry}
  end

  defp put_skip(skipped, _issue, nil), do: skipped
  defp put_skip(skipped, issue, reason), do: Map.put(skipped, issue.id, {issue, reason})

  # Try transient declines once again after a successful start opens the
  # next selection. Explicit retry timers and dependency holds keep their gates.
  defp next_slot(state, batch) do
    retry = if Slots.available_slots(state) > 0, do: Enum.reverse(batch.retry), else: []
    {retry, Map.drop(batch.skipped, Enum.map(retry, & &1.id))}
  end

  defp retry_next_slot?({kind, _reason}) when kind in [:capacity_denied, :capacity_held, :machine_grant], do: true

  defp retry_next_slot?(reason),
    do: reason in [:github_budget_hold, :tracker_revalidation_failed, :dependency_hydration_failed, :shared_lease_unavailable, :shared_lease_held, :worker_capacity, :instance_ownership_unavailable]

  @doc "Obtains the machine grant and records the result of an automatic start."
  @spec start_with_grant(State.t(), Issue.t(), keyword(), (-> State.t())) :: State.t()
  def start_with_grant(state, %Issue{id: id} = issue, opts, start) do
    ordered_locally? = Keyword.has_key?(opts, :dispatch_skips) or opts[:automatic_recovery] == true

    case MachineGrant.acquire(id, MachineGrant.feature(issue), ordered_locally?) do
      :ok ->
        case start.() do
          %{running: %{^id => _entry}} = next -> record_start(next, issue, opts)
          next -> next
        end

      {:error, reason} ->
        Candidates.emit_dispatch_attempt_decline(state, issue, {:machine_grant, reason}, false)
    end
  end

  defp record_start(state, chosen, opts) do
    cond do
      skipped = opts[:dispatch_skips] ->
        record_selection(state, chosen, Map.values(skipped))

      opts[:automatic_recovery] == true ->
        skipped = for {id, issue} <- state.last_polled_issues, reason = Map.get(state.dispatch_declines, id), do: {issue, reason}
        record_selection(state, chosen, skipped)

      true ->
        state
    end
  end

  defp record_selection(state, chosen, skipped) do
    skipped =
      for {issue, reason} <- skipped, higher_priority?(issue, chosen), not Map.has_key?(state.running, issue.id) do
        %{ticket: issue.identifier, reason: if(is_atom(reason), do: Atom.to_string(reason), else: inspect(reason))}
      end

    entry = %{chosen: chosen.identifier, skipped: Enum.sort_by(skipped, & &1.ticket), at: state.running[chosen.id].started_at}
    Logger.info("orchestrator.dispatch selection=#{inspect(entry, limit: :infinity)}")
    next = %{state | dispatch_selections: Enum.take([entry | state.dispatch_selections], @recent_selections)}
    if next.snapshot_ready? and next.candidate_snapshot_fresh?, do: StatusReport.publish_snapshot(next)
    next
  end

  defp higher_priority?(issue, other), do: DispatchPolicy.priority_rank(issue.priority) < DispatchPolicy.priority_rank(other.priority)

  defp schedule_startup_todo_alert(state, issue, %{initial?: true} = batch) do
    if DispatchPolicy.normalize_issue_state(issue.state) == "todo" do
      worker_host = State.WorkerHost.running_worker_host(state, issue.id)
      topic = "ticket.#{issue.identifier}.issue.label.added.agent.todo"
      Process.send_after(self(), {:emit_system_alert, topic, issue, worker_host}, batch.index * 1_000)
      %{batch | index: batch.index + 1}
    else
      batch
    end
  end

  defp schedule_startup_todo_alert(_state, _issue, batch), do: batch
end
