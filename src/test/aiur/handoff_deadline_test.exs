defmodule Aiur.HandoffDeadlineTest do
  use ExUnit.Case, async: false

  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff

  defmodule Owner do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:prepare_handoff_snapshot, _from, state) do
      calls = Map.get(state, :snapshot_calls, 0)
      if calls > 0, do: Process.sleep(Map.get(state, :refresh_delay_ms, 0))
      Handoff.hold_dispatch(Map.put(state, :snapshot_calls, calls + 1))
    end

    def handle_call(:cancel_handoff, _from, state), do: Handoff.release_dispatch(state)
    def handle_call(:held?, _from, state), do: {:reply, Handoff.dispatch_held?(), state}
  end

  defmodule Runner do
    use GenServer

    def start_link(_args), do: GenServer.start_link(__MODULE__, :held)
    def init(state), do: {:ok, state}
  end

  test "multiple stuck runner snapshots share one deadline" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    pids = for _ <- 1..2, do: start_supervised!({Runner, []}, id: make_ref())

    running =
      Map.new(Enum.zip(["1", "2"], pids), fn {id, pid} ->
        {id, %{pid: pid, issue: %Aiur.Issue{id: id, identifier: "ISSUE-#{id}"}, session_execution: %{backend: "codex"}}}
      end)

    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}}})
    dir = Path.join(System.tmp_dir!(), "handoff-deadline-#{System.unique_integer([:positive])}")
    parent = self()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Handoff.reset()
    end)

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{agents: agents}} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               dir: dir,
               config_fingerprint: "config",
               snapshot_timeout_ms: 40,
               hold: fn _ -> :ok end,
               abort: fn pid -> send(parent, {:aborted, pid}) end,
               snapshot: fn pid ->
                 send(parent, {:snapshot_started, pid})
                 Process.sleep(500)
                 {:error, :snapshot_timeout}
               end
             )

    # Leave scheduler headroom while still distinguishing two serial 500ms calls.
    assert System.monotonic_time(:millisecond) - started < 800
    assert Enum.map(agents, & &1["fallback_reason"]) == ["snapshot_timeout", "snapshot_timeout"]
    assert_receive {:snapshot_started, _}, 1_000
    assert_receive {:snapshot_started, _}, 1_000
    assert_receive {:aborted, _}, 1_000
    assert_receive {:aborted, _}, 1_000
  end

  test "slow orchestrator refresh after a snapshot timeout still prepares fallbacks" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    [stuck, healthy] = for _ <- 1..2, do: start_supervised!({Runner, []}, id: make_ref())

    running = %{
      "stuck" => %{pid: stuck, issue: %Aiur.Issue{id: "stuck", identifier: "ISSUE-stuck"}, session_execution: %{backend: "codex"}},
      "healthy" => %{pid: healthy, issue: %Aiur.Issue{id: "healthy", identifier: "ISSUE-healthy"}, session_execution: %{backend: "codex"}}
    }

    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}, refresh_delay_ms: 20}})
    dir = Path.join(System.tmp_dir!(), "handoff-slow-refresh-#{System.unique_integer([:positive])}")
    parent = self()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Handoff.reset()
    end)

    assert {:ok, %{agents: agents}} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               dir: dir,
               config_fingerprint: "config",
               prepare_timeout_ms: 6_000,
               snapshot_timeout_ms: 40,
               hold: fn _ -> :ok end,
               abort: fn pid -> send(parent, {:aborted, pid}) end,
               snapshot: fn pid ->
                 if pid == stuck do
                   send(parent, :stuck_snapshot_started)
                   Process.sleep(500)
                   {:error, :snapshot_timeout}
                 else
                   {:ok, %{"transport" => %{"kind" => "relay"}}}
                 end
               end
             )

    assert Enum.count(agents, &(&1["fallback_reason"] == "snapshot_timeout")) == 1
    assert Enum.count(agents, &is_nil(&1["fallback_reason"])) == 1
    assert_receive :stuck_snapshot_started, 1_000
    assert_receive {:aborted, ^stuck}, 1_000
  end

  test "prepare deadline aborts runners and releases dispatch when refresh times out" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    runner = start_supervised!({Runner, []}, id: make_ref())
    running = %{"stuck" => %{pid: runner, issue: %Aiur.Issue{id: "stuck", identifier: "ISSUE-stuck"}, session_execution: %{backend: "codex"}}}
    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}, refresh_delay_ms: 6_000}})
    parent = self()

    assert {:error, {:orchestrator_call_failed, {:timeout, _}}} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               config_fingerprint: "config",
               prepare_timeout_ms: 5_300,
               snapshot_timeout_ms: 40,
               hold: fn _ -> :ok end,
               abort: fn pid -> send(parent, {:aborted, pid}) end,
               snapshot: fn _ ->
                 Process.sleep(500)
                 {:error, :snapshot_timeout}
               end
             )

    assert_receive {:aborted, ^runner}, 1_000
    refute GenServer.call(owner, :held?)
  end

  test "runner hold failure aborts the fleet and releases dispatch" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    runner = start_supervised!({Runner, []}, id: make_ref())
    running = %{"runner" => %{pid: runner, issue: %Aiur.Issue{id: "runner", identifier: "ISSUE-runner"}}}
    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}}})
    parent = self()

    assert {:error, {:prepare_exception, %RuntimeError{message: "runner already exited"}}} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               config_fingerprint: "config",
               hold: fn _ -> raise "runner already exited" end,
               abort: fn pid -> send(parent, {:aborted, pid}) end
             )

    assert_receive {:aborted, ^runner}, 1_000
    refute GenServer.call(owner, :held?)
  end
end
