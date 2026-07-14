defmodule Aiur.Orchestrator.SlotsTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State

  describe "max_concurrent_agent_limit/1" do
    test "prefers session override over state field" do
      state = %State{session_max_concurrent_agents: 3, max_concurrent_agents: 7}

      assert Slots.max_concurrent_agent_limit(state) == 3
    end

    test "uses state field when session override is absent" do
      state = %State{session_max_concurrent_agents: nil, max_concurrent_agents: 7}

      assert Slots.max_concurrent_agent_limit(state) == 7
    end
  end

  describe "available_slots/1" do
    test "subtracts active and paused entries and floors at zero" do
      state = %State{
        max_concurrent_agents: 3,
        running: %{
          "active" => running_entry(:working),
          "sleeping" => running_entry(:sleeping),
          "paused" => running_entry(:paused),
          "completed" => running_entry(:completed),
          "deactivated" => running_entry(:deactivated)
        }
      }

      assert Slots.available_slots(state) == 0
    end

    test "releases CI-wait pauses while other pauses keep their reservation" do
      state = %State{
        max_concurrent_agents: 3,
        running: %{
          "active" => running_entry(:working),
          "ci-wait" => running_entry(:paused, nil, :ci_wait),
          "operator" => running_entry(:paused, nil, :operator_pause)
        }
      }

      assert Slots.available_slots(state) == 1
    end
  end

  describe "max_concurrent_agent_status/1" do
    test "reports draining when active is above max" do
      state = %State{
        session_max_concurrent_agents: 1,
        max_concurrent_agents: 3,
        running: %{
          "one" => running_entry(:working),
          "two" => running_entry(:sleeping),
          "paused" => running_entry(:paused)
        }
      }

      assert %{
               active: 2,
               paused: 1,
               configured: 3,
               max: 1,
               session_override?: true,
               draining?: true
             } = Slots.max_concurrent_agent_status(state)
    end
  end

  describe "worker host slots" do
    test "running_worker_host_count/2 counts only active entries on a host" do
      running = %{
        "active-a" => running_entry(:working, "worker-a"),
        "sleeping-a" => running_entry(:sleeping, "worker-a"),
        "paused-a" => running_entry(:paused, "worker-a"),
        "completed-a" => running_entry(:completed, "worker-a"),
        "active-b" => running_entry(:working, "worker-b")
      }

      assert Slots.running_worker_host_count(running, "worker-a") == 2
    end
  end

  describe "launch_max_concurrent_agents_override/0" do
    test "reads positive integer app env override" do
      previous = Application.get_env(:aiur, :max_concurrent_agents_override)
      Application.put_env(:aiur, :max_concurrent_agents_override, 4)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:aiur, :max_concurrent_agents_override),
          else: Application.put_env(:aiur, :max_concurrent_agents_override, previous)
      end)

      assert Slots.launch_max_concurrent_agents_override() == 4

      Application.put_env(:aiur, :max_concurrent_agents_override, 0)
      assert Slots.launch_max_concurrent_agents_override() == nil
    end
  end

  defp running_entry(status, worker_host \\ nil, paused_reason \\ nil) do
    entry = %{
      control: %{status: status},
      worker_host: worker_host,
      issue: %Issue{id: "issue-#{status}", identifier: "repo##{status}", state: "todo"}
    }

    if is_nil(paused_reason), do: entry, else: Map.put(entry, :paused_reason, paused_reason)
  end
end
