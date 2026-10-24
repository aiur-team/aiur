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

      if calls > 0 and state[:refresh_gate] do
        send(state.refresh_gate, {:refresh_waiting, self()})

        receive do
          :release_refresh -> :ok
        end
      end

      Handoff.hold_dispatch(Map.put(state, :snapshot_calls, calls + 1))
    end

    def handle_call(:cancel_handoff, _from, state), do: Handoff.release_dispatch(state)
    def handle_call(:held?, _from, state), do: {:reply, Handoff.dispatch_held?(), state}

    def handle_info({:handoff_expired, handoff_id, token}, state) do
      Handoff.expire_prepared(state, handoff_id, token)
    end
  end

  defmodule Runner do
    use GenServer

    def start_link(_args), do: GenServer.start_link(__MODULE__, :held)
    def init(state), do: {:ok, state}
  end

  defmodule ExpiringRunner do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call(:parent, _from, parent), do: {:reply, parent, parent}

    def handle_info(:handoff_hold, parent), do: {:noreply, parent}

    def handle_info(message, parent) do
      send(parent, {:runner_message, message})
      {:noreply, parent}
    end
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

    task =
      Task.async(fn ->
        Handoff.prepare(
          orchestrator: owner,
          ledger: ledger,
          dir: dir,
          config_fingerprint: "config",
          snapshot_timeout_ms: 40,
          hold: fn _ -> :ok end,
          abort: fn pid -> send(parent, {:aborted, pid}) end,
          snapshot: fn pid ->
            send(parent, {:snapshot_started, pid, self()})

            receive do
              :release_snapshot -> {:error, :snapshot_timeout}
            after
              2_000 -> {:error, :snapshot_timeout}
            end
          end
        )
      end)

    started =
      for _ <- 1..2 do
        assert_receive {:snapshot_started, _, worker}, 1_000
        worker
      end

    Enum.each(started, &send(&1, :release_snapshot))
    assert {:ok, %{agents: agents}} = Task.await(task, 2_000)
    assert Enum.map(agents, & &1["fallback_reason"]) == ["snapshot_timeout", "snapshot_timeout"]
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

    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}, refresh_gate: self()}})
    dir = Path.join(System.tmp_dir!(), "handoff-slow-refresh-#{System.unique_integer([:positive])}")
    parent = self()

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Handoff.reset()
    end)

    task =
      Task.async(fn ->
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

              receive do
                :release_snapshot -> {:error, :snapshot_timeout}
              end
            else
              {:ok, %{"transport" => %{"kind" => "relay"}}}
            end
          end
        )
      end)

    assert_receive :stuck_snapshot_started, 1_000
    assert_receive {:refresh_waiting, ^owner}, 1_000
    send(owner, :release_refresh)
    assert {:ok, %{agents: agents}} = Task.await(task, 2_000)

    assert Enum.count(agents, &(&1["fallback_reason"] == "snapshot_timeout")) == 1
    assert Enum.count(agents, &is_nil(&1["fallback_reason"])) == 1
    assert_receive {:aborted, ^stuck}, 1_000
  end

  test "prepare deadline aborts runners and releases dispatch when refresh times out" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    runner = start_supervised!({Runner, []}, id: make_ref())
    running = %{"stuck" => %{pid: runner, issue: %Aiur.Issue{id: "stuck", identifier: "ISSUE-stuck"}, session_execution: %{backend: "codex"}}}
    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}, refresh_gate: self()}})
    parent = self()

    task =
      Task.async(fn ->
        Handoff.prepare(
          orchestrator: owner,
          ledger: ledger,
          config_fingerprint: "config",
          prepare_timeout_ms: 5_300,
          snapshot_timeout_ms: 40,
          hold: fn _ -> :ok end,
          abort: fn pid -> send(parent, {:aborted, pid}) end,
          snapshot: fn _ -> {:error, :snapshot_timeout} end
        )
      end)

    assert_receive {:refresh_waiting, ^owner}, 1_000
    Process.send_after(owner, :release_refresh, 5_500)
    assert {:error, {:orchestrator_call_failed, {:timeout, _}}} = Task.await(task, 12_000)

    assert_receive {:aborted, ^runner}, 1_000
    refute GenServer.call(owner, :held?)
  end

  test "prepared handoff expiry aborts runners and releases dispatch" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    runner = start_supervised!({ExpiringRunner, self()}, id: make_ref())
    assert GenServer.call(runner, :parent) == self()
    running = %{"runner" => %{pid: runner, issue: %Aiur.Issue{id: "runner", identifier: "ISSUE-runner"}}}
    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}}})
    dir = Path.join(System.tmp_dir!(), "handoff-expiry-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Handoff.reset()
    end)

    assert {:ok, _result} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               dir: dir,
               config_fingerprint: "config",
               prepared_expiry_ms: 100,
               snapshot: fn _ -> {:ok, %{"transport" => %{"kind" => "relay"}}} end
             )

    assert Handoff.active?()
    assert_receive {:runner_message, :handoff_abort}, 5_000
    refute Handoff.active?()
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
