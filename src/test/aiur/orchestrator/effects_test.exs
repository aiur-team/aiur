defmodule Aiur.Orchestrator.EffectsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog
  alias Aiur.Orchestrator.{PushRouting, Reconciler, State, TicketTransition}

  test "revoked running issue returns a terminate effect without performing teardown" do
    {issue, entry, state} = running_issue("effect-revoked")
    issue = %{issue | dispatch_authorized?: false, dispatch_authorization: :denied}

    {pending, effects} =
      Reconciler.reconcile_issue_effects(issue, state, MapSet.new(["in-progress"]), MapSet.new(["done"]), fn _, _ -> :ok end, fn _ -> :ok end)

    assert effects == [{:terminate, issue.id, false}]
    assert Map.take(pending.running[issue.id], Map.keys(entry)) == entry
    assert MapSet.member?(pending.claimed, issue.id)

    applied = TicketTransition.apply_effects(pending, effects)
    refute Map.has_key?(applied.running, issue.id)
    refute MapSet.member?(applied.claimed, issue.id)

    reconciled = Reconciler.reconcile_issue_state(issue, state, MapSet.new(["in-progress"]), MapSet.new(["done"]), fn _, _ -> :ok end, fn _ -> :ok end)
    refute Map.has_key?(reconciled.running, issue.id)
  end

  test "effects apply in emission order before teardown of the same issue" do
    {issue, entry, state} = running_issue("effect-order")

    log =
      capture_log(fn ->
        applied = TicketTransition.apply_effects(state, [{:transition_control, entry, :sleeping, "effects-order"}, {:terminate, issue.id, false}])
        refute Map.has_key?(applied.running, issue.id)
        refute MapSet.member?(applied.claimed, issue.id)
      end)

    assert log =~ "working -> sleeping reason=effects-order"
  end

  test "single resume effect preserves capacity failure and paused state" do
    {issue, entry, state} = running_issue("effect-cap")
    entry = %{entry | control: %{status: :paused}}
    {busy, busy_entry, _} = running_issue("effect-busy")
    state = %{state | running: %{issue.id => entry, busy.id => busy_entry}, max_concurrent_agents: 1}

    assert {{:error, :max_concurrent_agents_reached}, ^state} = TicketTransition.apply_effect(state, {:resume_paused, entry, false})
  end

  test "stream idle emits a control effect and the GenServer callback applies it" do
    {issue, entry, state} = running_issue("effect-idle")
    assert {^state, [{:transition_control, ^entry, :sleeping, "stream.idle_close"}]} = PushRouting.sleeping_effects(state, issue.identifier)
    assert {:noreply, next} = Aiur.Orchestrator.handle_cast({:mark_sleeping, issue.identifier}, state)
    assert next.running[issue.id].control.status == :sleeping
    assert {^next, []} = PushRouting.sleeping_effects(next, issue.identifier)
  end

  for {issue_state, effect} <- [{"ci-wait", :pause_for_ci_wait}, {"human-review", :maybe_deactivate_human_review}, {"error", :preserve_on_external_error}] do
    test "#{issue_state} reconciliation returns its transition request" do
      {issue, entry, state} = running_issue("effect-#{unquote(issue_state)}")
      observed = %{issue | state: unquote(issue_state)}
      {pending, effects} = Reconciler.reconcile_issue_effects(observed, state, MapSet.new(["in-progress"]), MapSet.new(["done"]), fn _, _ -> :ok end, fn _ -> :ok end)

      assert effects == [{unquote(effect), observed}]
      assert Map.take(pending.running[issue.id], Map.keys(entry)) == entry
    end
  end

  test "future regression guard: termination frees capacity before the next issue resumes" do
    {first, first_entry, state} = running_issue("effect-first")
    {second, second_entry, _} = running_issue("effect-second")
    first = %{first | dispatch_authorized?: false, dispatch_authorization: :denied}
    second_entry = Map.merge(second_entry, %{pid: self(), control: %{status: :paused, can_interrupt: true}, paused_reason: :before_run_failure})
    state = %{state | running: %{first.id => first_entry, second.id => second_entry}, max_concurrent_agents: 1}

    next = Reconciler.reconcile_running_issue_states([first, second], state, MapSet.new(["in-progress"]), MapSet.new(["done"]))
    refute Map.has_key?(next.running, first.id)
    assert next.running[second.id].control.status == :working
    assert next.running[second.id].before_run_resume_attempts == 1
    assert_received {:resume_agent, request_id}
    assert is_integer(request_id) and request_id > 0
  end

  test "future regression guard: a deferred resume neither burns an attempt nor messages the worker" do
    {issue, entry, state} = running_issue("effect-deferred")
    {busy, busy_entry, _} = running_issue("effect-occupied")
    entry = Map.merge(entry, %{pid: self(), control: %{status: :paused, can_interrupt: true}, paused_reason: :before_run_failure, before_run_resume_attempts: 0})
    state = %{state | running: %{issue.id => entry, busy.id => busy_entry}, max_concurrent_agents: 1}

    next = Reconciler.maybe_reactivate_or_refresh(state, issue)
    assert next.running[issue.id].control.status == :paused
    assert next.running[issue.id].before_run_resume_attempts == 0
    refute_received {:resume_agent, _}
  end

  defp running_issue(id) do
    issue = %Issue{id: id, identifier: id, state: "in-progress"}
    entry = %{issue: issue, identifier: id, pid: nil, ref: nil, control: %{status: :working}, started_at: DateTime.utc_now()}
    {issue, entry, %State{running: %{id => entry}, claimed: MapSet.new([id])}}
  end
end
