defmodule Aiur.HandoffDeadlineTest do
  use ExUnit.Case, async: false

  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff

  defmodule Owner do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:prepare_handoff_snapshot, _from, state), do: Handoff.hold_dispatch(state)
    def handle_call(:cancel_handoff, _from, state), do: Handoff.release_dispatch(state)
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
               end
             )

    assert System.monotonic_time(:millisecond) - started < 250
    assert Enum.map(agents, & &1["fallback_reason"]) == ["snapshot_timeout", "snapshot_timeout"]
    assert_receive {:snapshot_started, _}
    assert_receive {:snapshot_started, _}
    assert_receive {:aborted, _}
    assert_receive {:aborted, _}
  end
end
