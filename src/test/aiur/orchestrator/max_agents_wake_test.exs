defmodule Aiur.Orchestrator.MaxAgentsWakeTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Lifecycle, Slots, State, TrackerTasks}

  defmodule SlowTrackerClient do
    def fetch_issue_states_by_ids(ids) do
      send(Application.fetch_env!(:aiur, :max_agents_tracker_owner), {:tracker_waiting, self(), ids})
      receive do: (:release -> {:ok, []})
    end
  end

  defp pending_state(overrides \\ %{}) do
    now = System.monotonic_time(:millisecond)
    state = %State{max_concurrent_agents: 16, last_dispatch_poll_at_ms: now - 30_000, github_poll_delays: %{firehose: 60_000}}
    state = Lifecycle.schedule_tick(struct!(state, overrides), 240_000)
    on_exit(fn -> Process.cancel_timer(state.tick_timer_ref) end)
    state
  end

  for {operation, value} <- [{:set, 24}, {:adjust, 8}] do
    test "#{operation} raise wakes dispatch at the poll floor" do
      state = pending_state()
      {:reply, {:ok, %{max: 24}}, next} = control(unquote(operation), state, unquote(value))
      on_exit(fn -> Process.cancel_timer(next.tick_timer_ref) end)
      assert (next.next_poll_due_at_ms - state.last_dispatch_poll_at_ms) in 60_000..61_000
      assert Process.read_timer(next.tick_timer_ref) in 25_000..30_000
      assert Process.read_timer(state.tick_timer_ref) == false
    end
  end

  # Future-regression guards: lower/same and wake policy already hold on main.
  for {operation, value} <- [{:set, 8}, {:set, 16}, {:adjust, -8}, {:adjust, 0}] do
    test "#{operation} #{value} keeps the pending tick" do
      state = pending_state()
      {:reply, {:ok, _status}, next} = control(unquote(operation), state, unquote(value))
      assert next.tick_timer_ref == state.tick_timer_ref
      assert next.tick_token == state.tick_token
      assert next.next_poll_due_at_ms == state.next_poll_due_at_ms
      assert Process.read_timer(next.tick_timer_ref) > 230_000
    end
  end

  test "raising a session override compares against the session cap" do
    state = pending_state(%{session_max_concurrent_agents: 8})
    {:reply, {:ok, %{max: 12}}, next} = Slots.set_max_concurrent_agents_call(state, 12)
    on_exit(fn -> Process.cancel_timer(next.tick_timer_ref) end)
    assert (next.next_poll_due_at_ms - state.last_dispatch_poll_at_ms) in 60_000..61_000
    assert Process.read_timer(state.tick_timer_ref) == false
  end

  # Future-regression guards for the existing wake policy and async tracker control budget.
  test "a raise never delays a tick already due before the floor" do
    state = pending_state() |> Lifecycle.schedule_tick(5_000)
    on_exit(fn -> Process.cancel_timer(state.tick_timer_ref) end)
    {:reply, {:ok, %{max: 24}}, next} = Slots.set_max_concurrent_agents_call(state, 24)
    assert next.tick_timer_ref == state.tick_timer_ref
    assert next.next_poll_due_at_ms == state.next_poll_due_at_ms
  end

  test "a raise with no scheduled tick does not restart polling" do
    state = %State{max_concurrent_agents: 16}
    {:reply, {:ok, %{max: 24}}, next} = Slots.set_max_concurrent_agents_call(state, 24)
    assert next == %{state | session_max_concurrent_agents: 24}
  end

  test "a raise leaves frozen polling unchanged" do
    state = pending_state(%{poll_frozen: true})
    {:reply, {:ok, %{max: 24}}, next} = Slots.set_max_concurrent_agents_call(state, 24)
    assert next == %{state | session_max_concurrent_agents: 24}
    assert Process.read_timer(next.tick_timer_ref) > 230_000
  end

  test "a raise returns within the control budget while a tracker read is blocked" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github")

    for {key, value} <- [github_client_module: SlowTrackerClient, max_agents_tracker_owner: self()] do
      previous = Application.get_env(:aiur, key)
      Application.put_env(:aiur, key, value)

      on_exit(fn ->
        if is_nil(previous), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, previous)
      end)
    end

    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :Control), initial_poll?: false})

    :sys.replace_state(pid, fn state ->
      state = %{state | max_concurrent_agents: 16, session_max_concurrent_agents: 16}
      TrackerTasks.start(state, :dispatch_poll, fn -> Aiur.Tracker.fetch_issue_states_by_ids(["3769"]) end, fn current, _ -> current end)
    end)

    receive_barrier({:tracker_waiting, worker, ["3769"]})
    on_exit(fn -> send(worker, :release) end)
    {elapsed_us, result} = :timer.tc(fn -> Orchestrator.set_max_concurrent_agents(pid, 24) end)
    assert {:ok, %{max: 24}} = result
    assert elapsed_us < 5_000_000
    assert Process.alive?(worker)
    assert %{max: 24} = Orchestrator.max_concurrent_agents(pid)
    send(worker, :release)
  end

  defp control(:set, state, value), do: Slots.set_max_concurrent_agents_call(state, value)
  defp control(:adjust, state, value), do: Slots.adjust_max_concurrent_agents_call(state, value)
end
