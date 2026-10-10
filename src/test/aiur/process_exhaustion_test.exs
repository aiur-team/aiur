defmodule Aiur.ProcessExhaustionTest do
  # async: false — swaps the application-wide command seam.
  use ExUnit.Case, async: false

  alias Aiur.{ProcessExhaustion, ProcessTree}

  setup do
    test_pid = self()

    Application.put_env(:aiur, :process_exhaustion,
      cmd_fun: fn command, _args, _opts ->
        send(test_pid, {:spawn_attempt, Path.basename(command)})
        :erlang.error(:eagain)
      end,
      emit_fun: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
    )

    on_exit(fn -> Application.delete_env(:aiur, :process_exhaustion) end)
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

  test "an unrelated spawn failure still raises" do
    Application.put_env(:aiur, :process_exhaustion, cmd_fun: fn _command, _args, _opts -> :erlang.error(:enoent) end)

    assert_raise ErlangError, fn -> ProcessExhaustion.cmd("missing", []) end
  end
end
