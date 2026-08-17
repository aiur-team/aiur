defmodule Aiur.OrchestratorMaxAgentsTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  defp running_entry(issue_id, identifier, status) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: nil},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  describe "--max-agents launch override" do
    test "seeds the session cap from :max_concurrent_agents_override at init" do
      previous = Application.get_env(:aiur, :max_concurrent_agents_override)
      Application.put_env(:aiur, :max_concurrent_agents_override, 2)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:aiur, :max_concurrent_agents_override),
          else: Application.put_env(:aiur, :max_concurrent_agents_override, previous)
      end)

      name = Module.concat(__MODULE__, :LaunchOverride)
      start_orchestrator(name)

      assert %{max: 2, configured: 10, session_override?: true} =
               Orchestrator.max_concurrent_agents(name)
    end

    test "no override leaves the session cap at the configured default" do
      previous = Application.get_env(:aiur, :max_concurrent_agents_override)
      Application.delete_env(:aiur, :max_concurrent_agents_override)

      on_exit(fn ->
        if not is_nil(previous),
          do: Application.put_env(:aiur, :max_concurrent_agents_override, previous)
      end)

      name = Module.concat(__MODULE__, :NoOverride)
      start_orchestrator(name)

      assert %{max: 10, session_override?: false} = Orchestrator.max_concurrent_agents(name)
    end
  end

  describe "set_max_concurrent_agents/2 (runtime absolute set)" do
    test "wakes reconciliation after changing dispatch capacity" do
      state = %State{
        max_concurrent_agents: 10,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000
      }

      assert {:reply, {:ok, %{max: 5}}, next} =
               Slots.apply_session_max_concurrent_agents(state, 5)

      assert next.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
      assert_receive {:tick, token}
      assert token == next.tick_token
    end

    test "does not wake reconciliation when the cap is unchanged" do
      token = make_ref()

      state = %State{
        max_concurrent_agents: 10,
        session_max_concurrent_agents: 5,
        tick_token: token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000
      }

      assert {:reply, {:ok, %{max: 5}}, ^state} =
               Slots.apply_session_max_concurrent_agents(state, 5)

      refute_receive {:tick, _token}
    end

    test "sets an absolute cap and reports it" do
      name = Module.concat(__MODULE__, :SetCap)
      start_orchestrator(name)

      assert {:ok, %{max: 5, session_override?: true, draining?: false}} =
               Orchestrator.set_max_concurrent_agents(name, 5)

      assert %{max: 5} = Orchestrator.max_concurrent_agents(name)
    end

    test "allows a cap below active count and reports drain state" do
      name = Module.concat(__MODULE__, :BelowActiveDrain)
      pid = start_orchestrator(name)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | session_max_concurrent_agents: 3,
            running: %{
              "i1" => running_entry("i1", "repo#1", :working),
              "i2" => running_entry("i2", "repo#2", :working),
              "i3" => running_entry("i3", "repo#3", :working),
              "i4" => running_entry("i4", "repo#4", :working)
            }
        }
      end)

      assert {:ok, %{active: 4, max: 3, draining?: true}} =
               Orchestrator.set_max_concurrent_agents(name, 3)

      assert %{active: 4, max: 3, draining?: true} = Orchestrator.max_concurrent_agents(name)
    end

    test "drained cap blocks queued dispatch until active drops below max" do
      running = %{
        "i1" => running_entry("i1", "repo#1", :working),
        "i2" => running_entry("i2", "repo#2", :working),
        "i3" => running_entry("i3", "repo#3", :working),
        "i4" => running_entry("i4", "repo#4", :working)
      }

      candidate = %Issue{
        id: "i5",
        identifier: "repo#5",
        state: "todo",
        title: "queued work"
      }

      state = %Orchestrator.State{
        max_concurrent_agents: 4,
        session_max_concurrent_agents: 3,
        running: running,
        claimed: MapSet.new(Map.keys(running))
      }

      refute DispatchPolicy.should_dispatch_issue?(candidate, state)

      one_finished = %{state | running: Map.delete(running, "i4")}
      refute DispatchPolicy.should_dispatch_issue?(candidate, one_finished)

      below_cap = %{state | running: running |> Map.delete("i4") |> Map.delete("i3")}
      assert DispatchPolicy.should_dispatch_issue?(candidate, below_cap)
    end

    test "adaptive capacity blocks normal dispatch before the static cap" do
      running = %{
        "i1" => running_entry("i1", "repo#1", :working),
        "i2" => running_entry("i2", "repo#2", :working)
      }

      candidate = %Issue{id: "i3", identifier: "repo#3", state: "todo", title: "queued work"}

      state = %Orchestrator.State{
        max_concurrent_agents: 10,
        effective_concurrent_agents: 2,
        running: running,
        claimed: MapSet.new(Map.keys(running))
      }

      refute DispatchPolicy.should_dispatch_issue?(candidate, state)

      assert DispatchPolicy.should_dispatch_issue?(candidate, %{state | running: Map.delete(running, "i2")})
    end

    test "returns :unavailable when the orchestrator is not running" do
      assert {:error, :unavailable} =
               Orchestrator.set_max_concurrent_agents(:nonexistent_orchestrator_xyz, 4)
    end
  end
end
