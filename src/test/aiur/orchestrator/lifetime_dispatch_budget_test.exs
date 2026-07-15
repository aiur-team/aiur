defmodule Aiur.Orchestrator.LifetimeDispatchBudgetTest do
  use ExUnit.Case, async: false

  alias Aiur.{DispatchBudgetStore, Issue, Orchestrator}
  alias Aiur.Orchestrator.Dispatcher
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

  defp thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  defp with_thrash_budget(state, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget, budget)

  # Each dispatch sits in its own lapsed window, so the per-window breaker never
  # trips — exactly the #1091 shape (85 cold dispatches, none circuit-broken).
  defp dispatch_n(state, n) do
    Enum.reduce(1..n, state, fn i, acc ->
      {:ok, next} = run(acc, i * (@window_ms + 1))
      next
    end)
  end

  @enabled """
  tracker:
    kind: memory
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
  test "stays healthy below the lifetime budget" do
    state = dispatch_n(%Orchestrator.State{}, 8)

    assert {:ok, _state} = run(state, 9 * (@window_ms + 1))
  end

  @tag config: @enabled
  test "an operator reset does not refund the lifetime budget" do
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

    assert %{lifetime: 1} = thrash_budget(state)[@issue_id]
    refute Map.has_key?(thrash_budget(state)[@issue_id], :window_start_ms)

    assert {:ok, state} = run(state, -576_460_751_000)
    assert %{count: 1, lifetime: 2, window_start_ms: -576_460_751_000} = thrash_budget(state)[@issue_id]
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
  test "a corrupt durable budget fails closed" do
    path = DispatchBudgetStore.path_for()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not-json")

    assert {:trip, state} = run(%Orchestrator.State{}, 0)
    assert %{lifetime: 10, tripped: :lifetime} = thrash_budget(state)[@issue_id]
  end

  @tag config: @enabled
  test "an unreadable durable budget fails closed" do
    unreadable_path = Path.join(Path.dirname(DispatchBudgetStore.path_for()), "is-a-directory")
    File.mkdir_p!(unreadable_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, unreadable_path)

    assert {:trip, state} = run(%Orchestrator.State{}, 0)
    assert %{lifetime: 10, tripped: :lifetime} = thrash_budget(state)[@issue_id]
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

  @tag config: """
       tracker:
         kind: memory
       agent:
         kind: codex
       """
  test "unset budget disables the latch (default is a no-op)" do
    state = dispatch_n(%Orchestrator.State{}, 30)

    assert {:ok, _state} = run(state, 31 * (@window_ms + 1))
  end
end
