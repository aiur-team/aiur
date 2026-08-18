defmodule Aiur.AgentResourceGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentResourceGuard

  test "agent_root_pids returns only local agent os pids" do
    entries = [
      {{:os_pid, 100}, :agent, %{}},
      {{:pane, "%1"}, :agent, %{}},
      {{:os_pid, 200}, :serve, %{}},
      {{:os_pid, 100}, :agent, %{}}
    ]

    assert AgentResourceGuard.agent_root_pids(entries) == [100]
  end

  test "synthetic_load_generator? recognizes known generator commands" do
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 1, comm: "yes", cmdline: "yes"})
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 2, comm: "bash", cmdline: "/usr/bin/stress --cpu 16"})
    assert AgentResourceGuard.synthetic_load_generator?(%{pid: 3, comm: "stress-ng", cmdline: "stress-ng --cpu 16"})

    refute AgentResourceGuard.synthetic_load_generator?(%{pid: 4, comm: "beam.smp", cmdline: "mix test --seed 229"})
    refute AgentResourceGuard.synthetic_load_generator?(%{pid: 5, comm: "bash", cmdline: "bash ./.repro_flake.sh"})
  end

  test "enforce_once trims excess yes descendants and preserves non-generators" do
    test_pid = self()
    yes_pids = Enum.to_list(201..216)
    mix_pid = 301

    children = fn
      100 -> yes_pids ++ [mix_pid]
      _ -> []
    end

    process_info = fn
      pid when pid in 201..216 -> %{pid: pid, comm: "yes", cmdline: "yes"}
      ^mix_pid -> %{pid: mix_pid, comm: "beam.smp", cmdline: "mix test --seed 229"}
      _ -> nil
    end

    result =
      AgentResourceGuard.enforce_once(
        cap: 3,
        entries_fun: fn -> [{{:os_pid, 100}, :agent, %{comm: "codex"}}] end,
        children_fun: children,
        process_info_fun: process_info,
        kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
      )

    expected_killed = Enum.to_list(204..216)
    assert result == [%{root_pid: 100, cap: 3, killed: expected_killed}]

    for pid <- expected_killed do
      assert_receive {:killed, ^pid}
    end

    refute_receive {:killed, 201}, 50
    refute_receive {:killed, 202}, 50
    refute_receive {:killed, 203}, 50
    refute_receive {:killed, ^mix_pid}, 50
  end

  test "enforce_once is disabled at cap zero" do
    assert [] =
             AgentResourceGuard.enforce_once(
               cap: 0,
               entries_fun: fn -> flunk("entries should not be read when disabled") end
             )
  end

  test "collect_descendants walks recursively" do
    children = fn
      1 -> [2, 3]
      2 -> [4]
      3 -> []
      4 -> []
    end

    assert AgentResourceGuard.collect_descendants(1, children_fun: children) == [2, 3, 4]
  end

  test "scheduled enforcement runs with injected process sources" do
    test_pid = self()

    {:ok, pid} =
      AgentResourceGuard.start_link(
        name: nil,
        interval_ms: 60_000,
        enforce_opts: [
          cap: 1,
          entries_fun: fn ->
            send(test_pid, :guard_enforced)
            []
          end
        ]
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    send(pid, :tick)
    assert_receive :guard_enforced
    assert Process.alive?(pid)
  end
end
