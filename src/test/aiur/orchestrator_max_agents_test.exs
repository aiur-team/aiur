defmodule Aiur.OrchestratorMaxAgentsTest do
  use Aiur.TestSupport

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
    test "sets an absolute cap and reports it" do
      name = Module.concat(__MODULE__, :SetCap)
      start_orchestrator(name)

      assert {:ok, %{max: 5, session_override?: true}} =
               Orchestrator.set_max_concurrent_agents(name, 5)

      assert %{max: 5} = Orchestrator.max_concurrent_agents(name)
    end

    test "rejects a cap below the active agent count without changing state" do
      name = Module.concat(__MODULE__, :BelowActive)
      pid = start_orchestrator(name)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | session_max_concurrent_agents: 3,
            running: %{
              "i1" => running_entry("i1", "repo#1", :working),
              "i2" => running_entry("i2", "repo#2", :working)
            }
        }
      end)

      assert {:error, :below_active_count} = Orchestrator.set_max_concurrent_agents(name, 1)
      assert %{max: 3} = Orchestrator.max_concurrent_agents(name)
    end

    test "returns :unavailable when the orchestrator is not running" do
      assert {:error, :unavailable} =
               Orchestrator.set_max_concurrent_agents(:nonexistent_orchestrator_xyz, 4)
    end
  end
end
