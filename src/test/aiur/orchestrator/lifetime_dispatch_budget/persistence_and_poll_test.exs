Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.LifetimeDispatchBudget.PersistenceAndPollTest do
  use Aiur.LifetimeDispatchBudgetCase, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.LifetimeDispatchBudgetCase, only: [run: 2, thrash_budget: 1, with_thrash_budget: 2, dispatch_n: 2]

  alias Aiur.AlertFeed
  alias Aiur.Config
  alias Aiur.DispatchBudgetStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.TrackerTasks

  @issue_id "issue-lifetime"
  @window_ms 60 * 1_000

  @enabled """
  tracker:
    kind: memory
    active_states:
      - todo
      - in-progress
      - rework
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  @tag config: @enabled
  test "a lifetime trip is durably moved to error exactly once" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime"}
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))
    parent = self()

    state =
      Dispatcher.persist_lifetime_trip(state, issue, fn identifier, target_state ->
        send(parent, {:durable_latch, identifier, target_state})
        :ok
      end)

    assert_receive {:durable_latch, "repo#lifetime", "error"}, 1000
    assert thrash_budget(state)[@issue_id].durable_latch_applied == true

    assert Dispatcher.persist_lifetime_trip(state, issue, fn _, _ ->
             flunk("durable latch must not be applied twice")
           end) == state
  end

  @tag config: @enabled
  test "async lifetime writes retain current alert fields and ignore a reset budget" do
    issue = %Issue{id: @issue_id, identifier: "repo#async-lifetime"}
    state = dispatch_n(%Orchestrator.State{snapshot_key: self()}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))
    parent = self()

    write = fn _, _ ->
      send(parent, {:latch_writer, self()})
      receive do: (:release -> :ok)
    end

    pending = Dispatcher.persist_lifetime_trip(state, issue, write)
    receive_barrier({:latch_writer, worker})
    send(worker, :release)
    receive_barrier({ref, result})
    current = update_in(pending.dispatch_recovery.codex_thrash_budget[@issue_id], &Map.put(&1, :alert_emitted, true))
    {:handled, next} = TrackerTasks.result(current, ref, result)
    assert thrash_budget(next)[@issue_id].durable_latch_applied
    assert thrash_budget(next)[@issue_id].alert_emitted

    pending = Dispatcher.persist_lifetime_trip(state, issue, write)
    receive_barrier({:latch_writer, worker})
    send(worker, :release)
    receive_barrier({ref, result})
    reset = with_thrash_budget(pending, %{@issue_id => %{lifetime: 0}})
    {:handled, next} = TrackerTasks.result(reset, ref, result)
    assert thrash_budget(next)[@issue_id] == %{lifetime: 0}
  end

  @tag config: @enabled
  test "the lifetime latch attention reaches the central alert feed" do
    # IssueSync rebuilds the persisted error cause after a restart from the
    # central feed alone (`AlertFeed.list(roots: [], log_roots: [...])`). A
    # latch attention written only to the workspace log is invisible there, so
    # the attention could never be resolved or rearmed.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime-central"}
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:trip, state} = run(state, 11 * (@window_ms + 1))

    # Alerts only route to a workspace log when that workspace directory
    # exists, which is true for any ticket that has run. Create it so this
    # exercises the production routing rather than the no-workspace fallback.
    workspace = Aiur.Workspace.workspace_path_under(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    Dispatcher.persist_lifetime_trip(state, issue, fn _identifier, _target_state -> :ok end)

    topic = "ticket.repo#lifetime-central.agent.attention.error-lifetime_latch"

    assert Enum.any?(
             AlertFeed.list(roots: []),
             &(&1["topic"] == topic)
           )
  end

  # One poll cycle as the orchestrator runs it: consult dispatch eligibility, and
  # only when it admits do the gate + commit that bill a lifetime unit. Both
  # halves are the production functions (`should_dispatch_issue?/2` is the poll
  # loop's per-issue gate in `Dispatcher.choose_issues/2`;
  # `record_dispatch_committed/2` is the sole lifetime billing point), so removing
  # the #1759 guard makes this helper bill and the assertions below fail.
  defp poll_cycle(state, %Issue{} = issue, cycle) do
    if DispatchPolicy.should_dispatch_issue?(issue, state) do
      {:ok, gated} = Dispatcher.check_thrash_budget(state, issue.id, cycle * (@window_ms + 1))
      Dispatcher.record_dispatch_committed(gated, issue.id)
    else
      state
    end
  end

  defp parked_issue(id, state_name) do
    %Issue{id: id, identifier: "repo##{id}", title: "Approved and queued", state: state_name}
  end

  @tag config: """
       tracker:
         kind: memory
         active_states:
           - todo
           - in-progress
           - rework
           - merging
           - ci-wait
       agent:
         kind: codex
         max_dispatches_per_ticket: 10
       """
  test "a merging or ci-wait ticket holds a steady lifetime count across poll cycles" do
    # #1759 acceptance: #1573 sat in `agent:merging` with PR #1607 approved and in
    # the merge queue and still burned 48 lifetime dispatches in ~50 minutes,
    # latching a ticket whose work was already finished and approved. The config
    # above reproduces that operator config — `merging` listed as an active state.
    for {id, state_name} <- [{"issue-merging", "merging"}, {"issue-ci-wait", "ci-wait"}] do
      issue = parked_issue(id, state_name)
      state = %Orchestrator.State{max_concurrent_agents: 5, last_polled_issues: %{id => issue}}

      assert {:ok, 0} = DispatchBudgetStore.lifetime(id)

      state =
        Enum.reduce(1..4, state, fn cycle, acc ->
          acc = poll_cycle(acc, issue, cycle)
          assert {:ok, 0} = DispatchBudgetStore.lifetime(id)
          acc
        end)

      # Four poll cycles later the ticket is still nowhere near the latch, and no
      # in-memory lifetime was accrued either.
      assert {:ok, 0} = DispatchBudgetStore.lifetime(id)
      assert :none = Dispatcher.dispatch_latch_status(state, id)
      refute Map.has_key?(thrash_budget(state), id)
    end

    # Control: an otherwise identical ticket in a real work state does bill, so
    # the steady counts above are the guard doing its job and not a harness that
    # never bills anything.
    working = parked_issue("issue-rework", "rework")
    working_state = %Orchestrator.State{max_concurrent_agents: 5, last_polled_issues: %{"issue-rework" => working}}

    working_state = Enum.reduce(1..4, working_state, &poll_cycle(&2, working, &1))

    assert {:ok, 4} = DispatchBudgetStore.lifetime("issue-rework")
    assert %{lifetime: 4} = thrash_budget(working_state)["issue-rework"]
  end

  @tag config: """
       tracker:
         kind: memory
       agent:
         kind: codex
       """
  test "unset budget disables the latch (default is a no-op)" do
    state = dispatch_n(%Orchestrator.State{}, 30)

    assert {:ok, _state} = run(state, 31 * (@window_ms + 1))
    assert :none = Dispatcher.dispatch_latch_status(state, @issue_id)
  end
end
