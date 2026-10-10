defmodule Aiur.ProcessExhaustionTest do
  # async: false — swaps the application-wide command seam.
  use ExUnit.Case, async: false

  alias Aiur.{ProcessExhaustion, ProcessTree}

  defmodule Sink do
    @moduledoc false
    def emit_system(topic, opts), do: send(Aiur.ProcessExhaustionTest, {:alert, topic, opts})
  end

  setup do
    test_pid = self()
    Process.register(test_pid, __MODULE__)
    signal = Application.get_env(:aiur, :signal)

    # The alert must travel the configured sink, the route production uses.
    Application.put_env(:aiur, :signal, alert_sink: Sink)

    Application.put_env(:aiur, :process_exhaustion_cmd_fun, fn command, _args, _opts ->
      send(test_pid, {:spawn_attempt, Path.basename(command)})
      :erlang.error(:eagain)
    end)

    on_exit(fn ->
      Application.put_env(:aiur, :signal, signal)
      Application.delete_env(:aiur, :process_exhaustion_cmd_fun)
    end)

    :ok
  end

  # `Aiur.Orchestrator` crashed in exactly this call: agent teardown walks the
  # tree with pgrep, and `open_port` raised `:eagain` on a host out of processes.
  @tag skip: Aiur.TestSupport.pgrep_skip_reason()
  test "the orchestrator's teardown tree walk survives open_port returning :eagain" do
    os_pid = String.to_integer(System.pid())

    assert ProcessTree.process_tree(os_pid) == [os_pid]
    assert_received {:spawn_attempt, "pgrep"}

    assert_received {:alert, "system.host.process_exhaustion", opts}
    assert opts[:needs_attention] == true
    assert opts[:message] =~ "could not spawn pgrep (eagain)"
  end

  test "a skipped probe reports its cause and alerts once, not per probe" do
    assert ProcessExhaustion.cmd("pgrep", ["-P", "1"]) == {:error, :eagain}
    assert ProcessExhaustion.cmd("ps", ["-p", "1"]) == {:error, :eagain}

    assert_received {:alert, "system.host.process_exhaustion", _opts}
    refute_received {:alert, _topic, _opts}
  end

  test "descriptor exhaustion skips the probe too" do
    Application.put_env(:aiur, :process_exhaustion_cmd_fun, fn _command, _args, _opts -> :erlang.error(:emfile) end)

    assert ProcessExhaustion.cmd("pgrep", ["-P", "1"]) == {:error, :emfile}
    assert_received {:alert, "system.host.process_exhaustion", opts}
    assert opts[:message] =~ "could not spawn pgrep (emfile)"
  end

  test "an unrelated spawn failure still raises" do
    Application.put_env(:aiur, :process_exhaustion_cmd_fun, fn _command, _args, _opts -> :erlang.error(:enoent) end)

    assert_raise ErlangError, fn -> ProcessExhaustion.cmd("missing", []) end
  end
end
