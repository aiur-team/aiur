defmodule Aiur.AgentResourceGuardAllCoreTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentResourceGuard
  alias Aiur.ExecutorBindings

  @spinners Enum.to_list(201..216)

  defp sample(pid, cpu), do: %{pid: pid, start: "1", state: "R", cpu: cpu, minflt: 10, io: 5, ctxt: 3}

  # The #4723 shape: an agent relay (100) runs the agent (101), whose shell
  # starts `sh -c 'while :; do :; done'` once per core.
  defp opts(spinners, test_pid) do
    [
      cap: 4,
      cores: 16,
      kill_detected: false,
      entries_fun: fn -> [{{:os_pid, 100}, :agent, [ticket: "4723"]}, {{:os_pid, 101}, :agent, [comm: "claude", ticket: "4723"]}] end,
      orphans_fun: fn -> [] end,
      children_fun: fn
        100 -> [101]
        101 -> [150]
        150 -> spinners
        _ -> []
      end,
      process_info_fun: fn pid -> %{pid: pid, comm: "sh", cmdline: "sh -c while :; do :; done"} end,
      cwd_fun: fn
        100 -> "/cfg/agent-relays/aiur.4723"
        101 -> "/ws/aiur/4723"
      end,
      alert_fun: fn topic, alert -> send(test_pid, {:alert, topic, alert}) end,
      kill_fun: fn pid -> send(test_pid, {:killed, pid}) end
    ]
  end

  defp tick(opts, n, tracked) do
    spinning = fn pid -> if pid in @spinners, do: sample(pid, n) end
    AgentResourceGuard.enforce([now_ms: n * 1_000, sample_fun: spinning] ++ opts, tracked)
  end

  test "an all-core spin loop is reported on the first sample pair, once, as the ticket's attention" do
    opts = opts(@spinners, self())

    assert {[], tracked} = tick(opts, 0, %{})
    assert {[result], _tracked} = tick(opts, 1, tracked)

    assert result == %{root_pid: 101, cap: 4, killed: [], reported: Enum.drop(@spinners, 4), workspace: "/ws/aiur/4723"}

    assert_receive {:alert, "ticket.4723.agent.attention.synthetic-load", alert}, 1000
    assert alert[:issue] == "4723"
    assert alert[:needs_attention] == true
    assert alert[:message] =~ "Agent workspace /ws/aiur/4723 exceeded the synthetic load cap of 4"
    refute_receive {:alert, _topic, _alert}, 50
  end

  test "the all-core spin is killed above the cap when configured" do
    opts = Keyword.put(opts(@spinners, self()), :kill_detected, true)

    {[], tracked} = tick(opts, 0, %{})
    assert {[%{killed: killed, reported: []}], _tracked} = tick(opts, 1, tracked)
    assert killed == Enum.drop(@spinners, 4)
    for pid <- killed, do: assert_receive({:killed, ^pid}, 1000)
  end

  # Guards against over-flagging; it passes without the all-core path too.
  test "fewer spinners than cores still wait out the busy window" do
    opts = opts(Enum.take(@spinners, 8), self())

    {[], tracked} = tick(opts, 0, %{})
    assert {[], _tracked} = tick(opts, 1, tracked)
    refute_receive {:alert, _topic, _alert}, 50
  end

  test "both synthetic-load alert topics reach the Executor's wake stream" do
    assert "system.agent.synthetic_load_cap" in ExecutorBindings.patterns()
    assert ExecutorBindings.attention_topic?("ticket.4723.agent.attention.synthetic-load")
  end

  test "each tick builds the children index once for all roots, and not at all without agents" do
    test_pid = self()

    index_fun = fn ->
      send(test_pid, :index_built)
      %{100 => [101], 101 => [150], 150 => @spinners}
    end

    opts = opts(@spinners, test_pid) |> Keyword.delete(:children_fun) |> Keyword.put(:children_index_fun, index_fun)

    {[], tracked} = tick(opts, 0, %{})
    assert_received :index_built
    refute_received :index_built
    assert {[%{root_pid: 101, reported: reported}], _tracked} = tick(opts, 1, tracked)
    assert reported == Enum.drop(@spinners, 4)
    assert_received :index_built
    refute_received :index_built

    assert {[], _tracked} = tick(Keyword.put(opts, :entries_fun, fn -> [] end), 2, %{})
    refute_received :index_built
  end

  # Covers the real /proc reader; the scan count is pinned by the test above.
  test "descendants are read from one /proc scan when no children_fun is given" do
    sleep = System.find_executable("sleep")
    port = Port.open({:spawn_executable, sleep}, [:binary, args: ["30"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true) end)

    assert os_pid in AgentResourceGuard.collect_descendants(String.to_integer(System.pid()))
  end
end
