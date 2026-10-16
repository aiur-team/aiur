Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.LifetimeDispatchBudget.LatchTest do
  use Aiur.LifetimeDispatchBudgetCase, async: false
  import Aiur.LifetimeDispatchBudgetCase, only: [run: 2, commit: 1, thrash_budget: 1, with_thrash_budget: 2, dispatch_n: 2]

  alias Aiur.DispatchBudgetStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Dispatcher

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
    Application.put_env(:aiur, :log_file, Path.join(Aiur.TestSupport.tmp_root!("aiur-lifetime-restart"), "aiur.log"))

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
end
