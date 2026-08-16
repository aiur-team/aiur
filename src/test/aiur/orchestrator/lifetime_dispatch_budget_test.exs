defmodule Aiur.Orchestrator.LifetimeDispatchBudgetTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, AlertFeed, Config, DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Workflow

  @issue_id "issue-lifetime"
  @window_ms 60 * 1_000

  setup %{config: config} do
    previous = Application.get_env(:aiur, :workflow_file_path)
    previous_store = Application.get_env(:aiur, :dispatch_budget_store_path)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_log_file = Application.get_env(:aiur, :log_file)
    dir = Path.join(System.tmp_dir!(), "aiur-lifetime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, ".aiurconfig")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)
    Application.delete_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :decision_state_dir, Path.join(dir, "stable-state"))
    Application.put_env(:aiur, :log_file, Path.join([dir, "session-one", "aiur.log"]))

    on_exit(fn ->
      File.rm_rf!(dir)

      if is_nil(previous) do
        Workflow.clear_workflow_file_path()
      else
        Workflow.set_workflow_file_path(previous)
      end

      if is_nil(previous_store) do
        Application.delete_env(:aiur, :dispatch_budget_store_path)
      else
        Application.put_env(:aiur, :dispatch_budget_store_path, previous_store)
      end

      if is_nil(previous_state_dir) do
        Application.delete_env(:aiur, :decision_state_dir)
      else
        Application.put_env(:aiur, :decision_state_dir, previous_state_dir)
      end

      if is_nil(previous_log_file) do
        Application.delete_env(:aiur, :log_file)
      else
        Application.put_env(:aiur, :log_file, previous_log_file)
      end
    end)

    :ok
  end

  defp run(state, now_ms), do: Dispatcher.check_thrash_budget(state, @issue_id, now_ms)

  defp commit(state), do: Dispatcher.record_dispatch_committed(state, @issue_id)

  defp thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  defp with_thrash_budget(state, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget, budget)

  # A committed dispatch = the gate passes (window) + the runner survives
  # provisioning (lifetime commit). Each sits in its own lapsed window, so the
  # per-window breaker never trips — exactly the #1091 shape (85 cold
  # dispatches, none circuit-broken) that the lifetime latch exists to bound.
  defp dispatch_n(state, n) do
    Enum.reduce(1..n, state, fn i, acc ->
      {:ok, gated} = run(acc, i * (@window_ms + 1))
      commit(gated)
    end)
  end

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
  test "latches after the lifetime budget even though every window lapses" do
    state = dispatch_n(%Orchestrator.State{}, 10)

    assert {:trip, tripped} = run(state, 11 * (@window_ms + 1))
    assert %{lifetime: 10, tripped: :lifetime} = thrash_budget(tripped)[@issue_id]

    assert {:trip, repeated} = run(tripped, 12 * (@window_ms + 1))
    assert repeated == tripped
  end

  @tag config: @enabled
  test "a latched ticket trips at exactly the cap (off-by-one reconciled)" do
    # The pre-#1453 predicate tripped on lifetime > max (i.e. max+1), so a
    # 10/10 ticket recomputed 11, refused, and rewrote 10 forever. Both
    # predicates now agree on `>=`: a 10/10 ticket trips and the durable store
    # is left untouched (no saturate-at-max rewrite loop).
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)
    state = with_thrash_budget(%Orchestrator.State{}, %{@issue_id => %{lifetime: 10, count: 0}})

    assert {:trip, tripped} = run(state, 0)
    assert %{lifetime: 10, tripped: :lifetime} = thrash_budget(tripped)[@issue_id]
    assert {:ok, 10} = DispatchBudgetStore.lifetime(@issue_id)
  end

  @tag config: @enabled
  test "the gate does not bill a lifetime unit; only a committed dispatch does" do
    # A preflight/prewarm/tracker-auth failure never reaches the runner's
    # commit point, so it must leave the counter unchanged.
    {:ok, state} = run(%Orchestrator.State{}, 1 * (@window_ms + 1))

    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
    assert %{count: 1, lifetime: 0} = thrash_budget(state)[@issue_id]

    committed = commit(state)
    assert {:ok, 1} = DispatchBudgetStore.lifetime(@issue_id)
    assert %{lifetime: 1} = thrash_budget(committed)[@issue_id]
  end

  @tag config: @enabled
  test "a preflight failure leaves the counter unchanged (acceptance class)" do
    # Simulates a dispatch that dies in provisioning: the gate passed, the
    # runner failed before `send_dispatch_committed`. No lifetime unit is
    # billed, so a ticket hammered by environment faults cannot be walked to
    # the latch without ever doing agent work.
    {:ok, state} = run(%Orchestrator.State{}, 1 * (@window_ms + 1))

    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)

    # A fresh dispatch attempt after the preflight failure is still admitted
    # and again bills nothing until it commits.
    assert {:ok, _again} = run(state, 2 * (@window_ms + 1))
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
  end

  @tag config: @enabled
  test "a prewarm-gate failure leaves the counter unchanged (acceptance class)" do
    # A prewarm-gate hold (#1404) parks the ticket before the runner starts —
    # the dispatch never reaches `send_dispatch_committed`, so it bills no
    # lifetime unit even across repeated holds.
    {:ok, state} = run(%Orchestrator.State{}, 1 * (@window_ms + 1))
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)

    assert {:ok, _again} = run(state, 2 * (@window_ms + 1))
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
  end

  @tag config: @enabled
  test "a tracker-auth failure leaves the counter unchanged (acceptance class)" do
    # A tracker 401/403 auth failure parks the ticket before provisioning — no
    # agent work, no lifetime unit. A ticket hammered by auth blips cannot be
    # walked to the latch without ever doing work.
    {:ok, state} = run(%Orchestrator.State{}, 1 * (@window_ms + 1))
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)

    assert {:ok, _again} = run(state, 2 * (@window_ms + 1))
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
  end

  # #1756: a rework turn that finds nothing to rework produces no push, so the
  # pull request head is unchanged at the next dispatch. Billing that turn walks
  # the ticket to the terminal lifetime latch for doing nothing — #1583 climbed
  # back to 43/40 twenty minutes after a reset entirely this way.
  defp with_observed_head(state, head_sha) do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", state: "rework"}

    %{
      state
      | last_polled_issues: Map.put(state.last_polled_issues, @issue_id, issue),
        ci_lifecycle: Map.put(state.ci_lifecycle, :poll_cache, %{"repo#lifetime" => %{head_sha: head_sha, pr_number: 1667, decision: :passed}})
    }
  end

  defp dispatch_at_head(state, head_sha, now_ms) do
    {:ok, gated} = run(with_observed_head(state, head_sha), now_ms)
    commit(gated)
  end

  @tag config: @enabled
  test "a no-op rework turn does not bill a lifetime dispatch unit" do
    state = dispatch_at_head(%Orchestrator.State{}, "aaa111", 1 * (@window_ms + 1))
    assert {:ok, 1} = DispatchBudgetStore.lifetime(@issue_id)

    # The turn ended without pushing: the head is still aaa111 on redispatch.
    state = dispatch_at_head(state, "aaa111", 2 * (@window_ms + 1))
    state = dispatch_at_head(state, "aaa111", 3 * (@window_ms + 1))

    assert {:ok, 1} = DispatchBudgetStore.lifetime(@issue_id)
    assert %{lifetime: 1} = thrash_budget(state)[@issue_id]

    # A turn that actually pushed moves the head and bills normally again.
    state = dispatch_at_head(state, "bbb222", 4 * (@window_ms + 1))
    assert {:ok, 2} = DispatchBudgetStore.lifetime(@issue_id)
    assert %{lifetime: 2} = thrash_budget(state)[@issue_id]
  end

  @tag config: @enabled
  test "an unknown pull request head bills every dispatch as before" do
    # No PR yet, an unreadable poll, or the REST fallback: without an observed
    # head there is no evidence the turn was a no-op, so the latch still bounds
    # the ticket exactly as it did pre-#1756.
    state = dispatch_n(%Orchestrator.State{}, 3)

    assert {:ok, 3} = DispatchBudgetStore.lifetime(@issue_id)
    assert %{lifetime: 3} = thrash_budget(state)[@issue_id]
  end

  @tag config: @enabled
  test "stays healthy below the lifetime budget" do
    state = dispatch_n(%Orchestrator.State{}, 8)

    assert {:ok, _state} = run(state, 9 * (@window_ms + 1))
  end

  @tag config: @enabled
  test "an operator resume does not refund the lifetime budget" do
    state = dispatch_n(%Orchestrator.State{}, 10)

    # Operator resume clears the window so the ticket can move again, but the
    # lifetime spend is real — otherwise a resume loop refunds it forever.
    state = Dispatcher.reset_thrash_budget(state, @issue_id)

    assert {:trip, _state} = run(state, 99 * (@window_ms + 1))
  end

  @tag config: @enabled
  test "an operator reset starts a fresh window with a negative monotonic clock" do
    {:ok, state} = run(%Orchestrator.State{}, -576_460_751_248)
    state = Dispatcher.reset_thrash_budget(state, @issue_id)

    # No committed lifetime yet, so a window-only reset fully clears the entry.
    refute Map.has_key?(thrash_budget(state), @issue_id)

    assert {:ok, state} = run(state, -576_460_751_000)
    assert %{count: 1, window_start_ms: -576_460_751_000} = thrash_budget(state)[@issue_id]
  end

  @tag config: @enabled
  test "a daemon restart does not refund persisted lifetime dispatches" do
    _state = dispatch_n(%Orchestrator.State{}, 10)
    stable_path = DispatchBudgetStore.path_for()
    Application.put_env(:aiur, :log_file, Path.join([System.tmp_dir!(), "session-two", "aiur.log"]))

    assert DispatchBudgetStore.path_for() == stable_path
    assert {:trip, restarted_state} = run(%Orchestrator.State{}, 11 * (@window_ms + 1))
    assert %{lifetime: 10, tripped: :lifetime} = thrash_budget(restarted_state)[@issue_id]
  end

  @tag config: @enabled
  test "a corrupt durable budget fails open instead of latching every ticket" do
    path = DispatchBudgetStore.path_for()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not-json")

    # Pre-#1453 a single corrupt file made persisted_lifetime return max and
    # latched every ticket in the repo at once. It now fails open (0) so the
    # gate admits and a commit still works.
    assert {:ok, state} = run(%Orchestrator.State{}, 0)
    assert commit(state) |> commit() |> thrash_budget() |> Map.get(@issue_id) |> Map.get(:lifetime) == 2
  end

  @tag config: @enabled
  test "an unreadable durable budget fails open" do
    unreadable_path = Path.join(Path.dirname(DispatchBudgetStore.path_for()), "is-a-directory")
    File.mkdir_p!(unreadable_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, unreadable_path)

    assert {:ok, state} = run(%Orchestrator.State{}, 0)
    assert commit(state) |> thrash_budget() |> Map.get(@issue_id) |> Map.get(:lifetime) == 1
  end

  @tag config: @enabled
  test "reset_lifetime_budget returns a latched ticket to dispatchable" do
    state = dispatch_n(%Orchestrator.State{}, 10)
    assert {:lifetime, 10, 10} = Dispatcher.dispatch_latch_status(state, @issue_id)

    {state, :ok} = Dispatcher.reset_lifetime_budget(state, @issue_id)

    assert :none = Dispatcher.dispatch_latch_status(state, @issue_id)
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)

    # A fresh dispatch commits cleanly — the ticket is no longer latched.
    assert {:ok, state} = run(state, 99 * (@window_ms + 1))
    assert %{lifetime: 1} = commit(state) |> thrash_budget() |> Map.get(@issue_id)
  end

  @tag config: @enabled
  test "dispatch_latch_status reports the latch only at or above the cap" do
    state = dispatch_n(%Orchestrator.State{}, 9)
    assert :none = Dispatcher.dispatch_latch_status(state, @issue_id)

    state = commit(state)
    assert {:lifetime, 10, 10} = Dispatcher.dispatch_latch_status(state, @issue_id)
  end

  @tag config: @enabled
  test "batch latch status reads the store once across the board" do
    issue_a = %Issue{id: "issue-a", identifier: "repo#a"}
    issue_b = %Issue{id: "issue-b", identifier: "repo#b"}
    :ok = DispatchBudgetStore.put_lifetime("issue-a", 10)

    state =
      %Orchestrator.State{last_polled_issues: %{"issue-a" => issue_a, "issue-b" => issue_b}}
      |> with_thrash_budget(%{"issue-a" => %{lifetime: 10, count: 0}})

    statuses = Dispatcher.dispatch_latch_statuses(state, ["issue-a", "issue-b"])

    assert statuses["issue-a"] == {:lifetime, 10, 10}
    assert statuses["issue-b"] == :none
  end

  @tag config: @enabled
  test "resume against a latched idle ticket reports the latch instead of no-opping" do
    issue = %Issue{
      id: @issue_id,
      identifier: "repo#lifetime",
      title: "Latched",
      state: "in-progress",
      paused: true,
      labels: ["agent:in-progress", "agent:paused"]
    }

    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    # `resume_issue/2` routes a no-running-agent resume to the queued path,
    # which must name the latch (not a generic `:dispatch_failed`).
    assert {{:error, :lifetime_dispatch_latch}, next_state} =
             PauseResume.resume_issue(state, "repo#lifetime")

    assert next_state.last_polled_issues[@issue_id].paused
    assert "agent:paused" in next_state.last_polled_issues[@issue_id].labels
  end

  @tag config: @enabled
  test "reset_dispatch_budget_call clears the in-memory and durable latch copies" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:reply, {:ok, :reset}, reset_state} =
             PauseResume.reset_dispatch_budget_call(state, "repo#lifetime")

    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert {:ok, 0} = DispatchBudgetStore.lifetime(@issue_id)
  end

  @tag config: @enabled
  test "public reset queues while the orchestrator mailbox is unresponsive" do
    name = Module.concat(__MODULE__, :SuspendedResetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :sys.resume(pid)
          Process.exit(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert {:ok, :queued} = PauseResume.reset_dispatch_budget(name, "repo#lifetime")
  end

  @tag config: @enabled
  test "public reset rejects an unavailable orchestrator instead of claiming it queued work" do
    missing = Module.concat(__MODULE__, :MissingResetOrchestrator)

    assert {:error, :unavailable} = PauseResume.reset_dispatch_budget(missing, "repo#lifetime")
  end

  @tag config: @enabled
  test "queued reset processing emits completion and failure outcomes" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)
    :ok = AgentPubSub.subscribe_agent(@issue_id)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    reset = PauseResume.reset_dispatch_budget_cast(state, issue.identifier)
    assert :none = Dispatcher.dispatch_latch_status(reset, @issue_id)

    assert_receive {:alert,
                    %{
                      name: "ticket.issue-lifetime.agent.attention.dispatch-budget-reset.resolved",
                      needs_attention: false
                    }},
                   2_000

    :ok = AgentPubSub.subscribe_agent("missing")
    _unchanged = PauseResume.reset_dispatch_budget_cast(reset, "missing")

    assert_receive {:alert,
                    %{
                      name: "ticket.missing.agent.attention.dispatch-budget-reset",
                      needs_attention: true
                    }},
                   2_000
  end

  @tag config: @enabled
  test "a durable reset failure is surfaced instead of reporting false success" do
    # #1453 review P2b: `reset_lifetime_budget/2` used to discard the durable
    # store's result, so `reset-budget` reported success while the latch would
    # survive a restart. A failed durable write must surface as an error.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "in-progress"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    # Point the durable store at an unreadable path so the reset write fails.
    unreadable_path = Path.join(Path.dirname(DispatchBudgetStore.path_for()), "is-a-directory")
    File.mkdir_p!(unreadable_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, unreadable_path)

    assert {:reply, {:error, {:budget_reset_failed, _reason}}, reset_state} =
             PauseResume.reset_dispatch_budget_call(state, "repo#lifetime")

    # The in-memory latch was cleared this generation, but the failure is
    # reported so the operator knows it will re-latch on restart.
    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
  end

  @tag config: @enabled
  test "reset-budget restores a latched agent:error ticket to a dispatchable state" do
    # #1453 review P2c: a latched ticket is durably moved to `agent:error`
    # (not an active state), so clearing the budget alone left it
    # undispatchable. `reset_dispatch_budget_call` must also restore it to
    # `rework` so the reset actually returns the ticket to the board.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Latched", state: "error"}
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    state =
      %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:reply, {:ok, :reset}, reset_state} =
             PauseResume.reset_dispatch_budget_call(state, "repo#lifetime")

    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert %Issue{state: "rework"} = reset_state.last_polled_issues[@issue_id]
    assert DispatchPolicy.should_dispatch_issue?(reset_state.last_polled_issues[@issue_id], reset_state)
  end

  @tag config: @enabled
  test "rework dispatchability is gated by the lifetime latch, not the rework state" do
    # #1453 review P2f: the original acceptance test only asserted the
    # (unchanged) `should_dispatch_issue?` predicate, which passed even before
    # the fix — rework was already an active state. This proves the latch is
    # the dispatch gate: the SAME rework ticket dispatches when not latched,
    # is refused by the dispatch gate when latched, and dispatches again after
    # the supported reset.
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", title: "Rework", state: "rework"}
    state = %Orchestrator.State{last_polled_issues: %{@issue_id => issue}}

    # Not latched: a full dispatch candidate with free capacity.
    assert DispatchPolicy.should_dispatch_issue?(issue, state)

    # Latched at the cap: the dispatch gate refuses even though the rework
    # ticket is otherwise a valid candidate — the latch is the gate.
    :ok = DispatchBudgetStore.put_lifetime(@issue_id, 10)

    latched =
      state
      |> with_thrash_budget(%{@issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}})

    assert {:lifetime, 10, 10} = Dispatcher.dispatch_latch_status(latched, @issue_id)
    assert {:trip, _} = Dispatcher.check_thrash_budget(latched, @issue_id, @window_ms + 1)

    # After the supported reset, the same rework ticket is dispatchable again.
    {reset_state, :ok} = Dispatcher.reset_lifetime_budget(latched, @issue_id)
    assert :none = Dispatcher.dispatch_latch_status(reset_state, @issue_id)
    assert DispatchPolicy.should_dispatch_issue?(issue, reset_state)
  end

  @tag config: @enabled
  test "redispatch preflight rejects the next dispatch when the lifetime latch is exhausted" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", selected_backend: "claude"}

    state =
      with_thrash_budget(%Orchestrator.State{}, %{
        @issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}
      })

    assert {:error, :thrash_circuit_open} =
             Dispatcher.redispatch_ready?(state, issue, nil, now_ms: @window_ms + 1)

    assert get_in(thrash_budget(state), [@issue_id, :lifetime]) == 10
  end

  @tag config: @enabled
  test "stateful redispatch admission returns the committed lifetime trip" do
    issue = %Issue{id: @issue_id, identifier: "repo#lifetime", selected_backend: "claude"}

    state =
      with_thrash_budget(%Orchestrator.State{}, %{
        @issue_id => %{window_start_ms: 0, count: 1, lifetime: 10}
      })

    trip = fn tripped_state, _issue ->
      update_in(tripped_state.dispatch_recovery.codex_thrash_budget[@issue_id], &Map.put(&1, :trip_observed, true))
    end

    assert {:error, :thrash_circuit_open, rejected_state} =
             Dispatcher.admit_redispatch(state, issue, nil,
               now_ms: @window_ms + 1,
               trip_fun: trip
             )

    assert %{tripped: :lifetime, trip_observed: true} =
             thrash_budget(rejected_state)[@issue_id]
  end

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

    assert_receive {:durable_latch, "repo#lifetime", "error"}
    assert thrash_budget(state)[@issue_id].durable_latch_applied == true

    assert Dispatcher.persist_lifetime_trip(state, issue, fn _, _ ->
             flunk("durable latch must not be applied twice")
           end) == state
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
    on_exit(fn -> File.rm_rf(workspace) end)

    Dispatcher.persist_lifetime_trip(state, issue, fn _identifier, _target_state -> :ok end)

    topic = "ticket.repo#lifetime-central.agent.attention.error-lifetime_latch"

    assert Enum.any?(
             AlertFeed.list(roots: [], log_roots: [Paths.log_root_dir()]),
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
