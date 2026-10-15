defmodule Aiur.HandoffTest do
  use ExUnit.Case, async: false

  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff
  alias Aiur.ProcessReaper

  defmodule Owner do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:prepare_handoff_snapshot, _from, state), do: Handoff.hold_dispatch(state)
    def handle_call(:cancel_handoff, _from, state), do: Handoff.release_dispatch(state)
    def handle_call(:held?, _from, state), do: {:reply, Handoff.dispatch_held?(), state}
    def handle_call(:handoff_state, _from, state), do: {:reply, state, state}
  end

  test "prepare holds dispatch, waits for tool completion, snapshots once and persists both agents" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    test_pid = self()

    tool =
      Task.async(fn ->
        ToolCallLedger.execute_cancellable(
          :tool,
          "fingerprint",
          fn ->
            send(test_pid, {:tool_running, self()})

            receive do
              :finish -> :result
            end
          end,
          ledger
        )
      end)

    assert_receive {:tool_running, tool_pid}, 1000

    state = %{
      running: %{"1" => %{pid: self(), issue: %Aiur.Issue{id: "1", identifier: "1"}}, "2" => %{pid: self(), issue: %Aiur.Issue{id: "2", identifier: "2"}}},
      retry_attempts: %{},
      dispatch_recovery: %{}
    }

    {:ok, owner} = start_supervised({Owner, state})
    dir = Path.join(System.tmp_dir!(), "handoff-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Handoff.reset()
    end)

    opts = [
      orchestrator: owner,
      ledger: ledger,
      dir: dir,
      config_fingerprint: "config",
      hold: fn _ -> send(test_pid, :held) end,
      snapshot: fn _ ->
        send(test_pid, :snapshotted)
        {:ok, %{"transport" => %{"acked_offset" => 17}, "pending_requests" => [%{"id" => 8, "method" => "turn/start"}]}}
      end
    ]

    prepare = Task.async(fn -> Handoff.prepare(opts) end)
    assert_receive :held, 1000
    assert GenServer.call(owner, :held?)
    refute_receive :snapshotted, 30
    send(tool_pid, :finish)
    assert :result == Task.await(tool)
    assert {:ok, result} = Task.await(prepare)
    assert {:ok, record} = Handoff.Record.read(dir: dir)
    assert length(record["agents"]) == 2
    assert Enum.all?(record["agents"], &(&1["transport"]["acked_offset"] == 17))
    assert {:ok, ^result} = Handoff.prepare(opts)
    assert_receive :snapshotted, 1000
    assert_receive :snapshotted, 1000
    refute_receive :snapshotted, 30
  end

  test "the daemon holds queued turn starts until handoff is cancelled" do
    server = start_supervised!({Aiur.Orchestrator, initial_poll?: false})
    identifier = "handoff-queue"

    :sys.replace_state(server, fn state ->
      {store, _item} = Aiur.AgentQueueStore.enqueue(state.queue_store, Aiur.AgentQueue.operator_message(identifier, "continue"))
      %{state | queue_store: store}
    end)

    GenServer.call(server, :prepare_handoff_snapshot)
    assert :empty = Aiur.Orchestrator.claim_next_queue_item(server, identifier)
    assert :ok = GenServer.call(server, :cancel_handoff)
    assert {:ok, item} = Aiur.Orchestrator.claim_next_queue_item(server, identifier)
    assert item.body.text == "continue"
  end

  test "an unsupported native backend falls back without preventing a compatible snapshot" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    native = %{pid: self(), issue: %Aiur.Issue{id: "native", identifier: "native"}, session_execution: %{backend: "muse"}}
    compatible = %{pid: self(), issue: %Aiur.Issue{id: "local", identifier: "local"}, session_execution: %{backend: "codex"}}
    state = %{running: %{"native" => native, "local" => compatible}, retry_attempts: %{}, dispatch_recovery: %{}}
    {:ok, owner} = start_supervised({Owner, state})
    dir = Path.join(System.tmp_dir!(), "handoff-native-#{System.unique_integer([:positive])}")
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
               hold: fn _ -> :ok end,
               snapshot: fn _ ->
                 send(parent, :snapshot)
                 {:ok, %{"transport" => %{"kind" => "relay"}}}
               end
             )

    assert_receive :snapshot, 1000
    refute_receive :snapshot, 20
    assert Enum.find(agents, &(&1["identifier"] == "native"))["fallback_reason"] == "relay_protocol"
    assert Handoff.protected?("local")
    refute Handoff.protected?("native")
  end

  test "failed snapshot aborts held runners and releases the dispatch hold" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    state = %{running: %{"1" => %{pid: self(), issue: %Aiur.Issue{id: "1", identifier: "1"}}}}
    {:ok, owner} = start_supervised({Owner, state})
    parent = self()

    assert {:error, {"1", :relay_gone}} =
             Handoff.prepare(
               orchestrator: owner,
               config_fingerprint: "config",
               ledger: ledger,
               hold: fn _ -> :ok end,
               snapshot: fn _ -> {:error, :relay_gone} end,
               abort: fn pid -> send(parent, {:aborted, pid}) end
             )

    expected = self()
    assert_receive {:aborted, ^expected}, 1000
    refute GenServer.call(owner, :held?)
  end

  test "expired tool execution becomes an uncertain tombstone and cannot run again" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    test_pid = self()

    tool =
      Task.async(fn ->
        ToolCallLedger.execute_cancellable(
          :slow,
          "same",
          fn ->
            send(test_pid, {:running, self()})

            receive do
              :finish -> :done
            end
          end,
          ledger
        )
      end)

    assert_receive {:running, worker}, 1000
    monitor = Process.monitor(worker)
    assert :ok = ToolCallLedger.quiesce(0, ledger)
    assert {:error, :outcome_uncertain} = ToolCallLedger.execute_cancellable(:slow, "same", fn -> flunk("executed twice") end, ledger)
    assert {:error, :outcome_uncertain} = Task.await(tool)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
  end

  test "inline and cancellable tool failures retain exception semantics and fence replay" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})

    Enum.each([:execute, :execute_cancellable], fn mode ->
      assert_raise RuntimeError, "tool failed", fn ->
        apply(ToolCallLedger, mode, [mode, "failure", fn -> raise "tool failed" end, ledger])
      end

      assert {:error, :outcome_uncertain} = apply(ToolCallLedger, mode, [mode, "failure", fn -> flunk("replayed failed tool") end, ledger])
    end)
  end

  test "tool worker inherits actor context and returns quota increments and deletions" do
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    Process.put(:handoff_actor, "ticket")
    Process.put(:handoff_quota, 2)
    Process.put(:handoff_deleted, true)

    assert "ticket" ==
             ToolCallLedger.execute_cancellable(
               :context,
               "same",
               fn ->
                 Process.put(:handoff_quota, Process.get(:handoff_quota) + 1)
                 Process.delete(:handoff_deleted)
                 Process.get(:handoff_actor)
               end,
               ledger
             )

    assert Process.get(:handoff_quota) == 3
    refute Process.get(:handoff_deleted)
  end

  test "handoff reaper keeps listed references and reaps an unlisted agent" do
    previous = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    on_exit(fn -> Application.put_env(:aiur, :process_reaper_registrations, previous) end)
    {:ok, reaper} = start_supervised({ProcessReaper, name: __MODULE__.Reaper})
    ProcessReaper.register(reaper, :agent, {:os_pid, 999_991}, [])
    ProcessReaper.register(reaper, :agent, {:os_pid, 999_992}, [])
    ProcessReaper.handoff([{:os_pid, 999_991}], reaper)
    parent = self()
    ProcessReaper.reap(reaper, [:agent], drain: true, kill_tree: &send(parent, {:killed, &1}))
    assert_receive {:killed, 999_992}, 1000
    refute_receive {:killed, 999_991}, 30
    assert [{{:os_pid, 999_991}, :agent, %{}}] == ProcessReaper.entries(reaper)
  end
end
