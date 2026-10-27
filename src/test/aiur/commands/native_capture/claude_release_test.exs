defmodule Aiur.Commands.NativeCapture.ClaudeReleaseTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.AppServer.NativeReplies
  alias Aiur.Claude.CodingAgent
  alias Aiur.Commands.{NativeAnswer, NativeCapture}
  alias Aiur.Commands.NativeCapture.Claude
  alias Aiur.{DecisionDispatch, DecisionPubSub, DecisionStore}
  alias Aiur.Events.Publisher
  alias Aiur.Workflow

  @ticket %{identifier: "979", title: "Native release"}
  @source %{agent_id: "agent", session_id: "session"}

  setup do
    dir = Aiur.TestSupport.tmp_root!("claude-release")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", workspace_root: dir)
    File.write!(Workflow.workflow_file_path(), "\ndecisions: {native_capture: {claude: true}}\n", [:append])
    assert :ok = Aiur.WorkflowStore.force_reload()
    key = {Publisher, :tracked_fn}
    previous = :persistent_term.get(key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> :persistent_term.put(key, previous) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})
    :ok = DecisionPubSub.subscribe()
    port = Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [:binary, :exit_status])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{dir: dir, store: store, port: port, ctx: %{ticket: @ticket, source: @source, store: store, tool_call_thread_id: "thread", turn_id: "turn", send_response: &CodingAgent.send_frame/2}}
  end

  test "holdable false records an open Command, writes release and later answers by message", c do
    assert :approved = Claude.handle(c.port, "request-1", Map.put(params(), "holdable", false), c.ctx)
    [decision] = DecisionStore.list(c.store)
    id = decision.decision_id
    text = NativeCapture.release_text(id)
    port = c.port
    assert {^port, {:data, line}} = receive_barrier({^port, {:data, _}})
    assert Jason.decode!(line) == %{"jsonrpc" => "2.0", "id" => "request-1", "result" => %{"answers" => %{"colour" => %{"answers" => [text]}}}}
    assert_released(c, id, :not_holdable)
    assert {:ok, %{decision: answered}} = DecisionStore.answer(id, %{expected_version: 1, option_id: "o1", idempotency_key: "answer"}, [actor: %{kind: :operator, id: "human"}], c.store)
    assert NativeAnswer.correlate(answered, answered.answer, %{}) == %{}
    owner = self()

    assert {:ok, _} =
             DecisionDispatch.dispatch(answered,
               attempt_id: "message",
               send_fun: fn _, _, payload ->
                 send(owner, {:message, payload})
                 {:ok, %{status: :accepted}}
               end
             )

    assert_received {:message, %{kind: :text, body: body, correlation: correlation}}
    assert body =~ "red"
    refute Map.has_key?(correlation, :native_ref)
  end

  test "re-fired released question is released again without reopening a hold", c do
    assert :approved = Claude.handle(c.port, "request-1", Map.put(params(), "holdable", false), c.ctx)
    [decision] = DecisionStore.list(c.store)
    assert_released(c, decision.decision_id, :not_holdable)
    assert :approved = Claude.handle(c.port, "request-2", params(), c.ctx)
    assert length(DecisionStore.list(c.store)) == 1
  end

  test "re-fired deferred question with a new request id keeps the same Command", c do
    assert {:held, ref, first} = Claude.handle(c.port, "request-1", params(), c.ctx)
    assert {:held, ^ref, second} = Claude.handle(c.port, "request-2", Map.put(params(), "itemId", "tool-refired"), c.ctx)
    assert second.decision_id == first.decision_id
    assert second.request_id == "request-2"
    assert length(DecisionStore.list(c.store)) == 1
  end

  test "replacement thread first contact releases persisted deferred Commands before turn start", c do
    assert {:held, _, info} = Claude.handle(c.port, "request-1", params(), c.ctx)
    # The real start_turn boundary does cleanup before writing turn/start.
    port = c.port
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "next"}}})}}})
    session = %{port: port, thread_id: "replacement", workspace: c.dir, store: c.store}
    assert {:ok, "next"} = CodingAgent.start_turn(session, "continue", @ticket)
    assert {:ok, %{native: %{hold: :released}}} = DecisionStore.get(info.decision_id, c.store)
    assert_released(c, info.decision_id, :session_gone)
    assert :ok = Claude.release_stale(session, @ticket)
  end

  test "future regression guard: same thread preserves its deferred question", c do
    assert {:held, _, info} = Claude.handle(c.port, "request-1", params(), c.ctx)
    assert :ok = Claude.release_stale(%{thread_id: "thread", store: c.store}, @ticket)
    assert {:ok, decision} = DecisionStore.get(info.decision_id, c.store)
    assert decision.native.hold == :deferred
  end

  test "turn starts with a warning when stale release cannot reach the store", c do
    dead_store = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_store)
    receive_barrier({:DOWN, ^monitor, :process, ^dead_store, _})

    log = capture_log(fn -> assert_turn_starts(c, dead_store) end)
    assert log =~ "[warning]"
    assert log =~ "Claude stale native release failed"
    assert log =~ "ticket=979"
    assert log =~ "thread=replacement"
    assert log =~ "noproc"
  end

  test "disabled Claude capture starts a turn without querying the store", c do
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "claude: true", "claude: false"))
    assert :ok = Aiur.WorkflowStore.force_reload()
    refute Aiur.Config.decisions_native_capture?(:claude)
    store = store_probe([])

    assert capture_log(fn -> assert_turn_starts(c, store) end) == ""
    refute_received {:store_call, _}
  end

  test "turn starts with a warning when stale release recording is rejected", c do
    assert {:held, _, info} = Claude.handle(c.port, "request-1", params(), c.ctx)
    store = store_probe(DecisionStore.list(c.store))

    log = capture_log(fn -> assert_turn_starts(c, store) end)
    assert_received {:store_call, :list}
    assert_received {:store_call, {:command_fact, id, :native_released, _, _}}
    assert id == info.decision_id
    assert log =~ "[warning]"
    assert log =~ "Claude stale native release failed"
    assert log =~ "store_read_only"
    assert {:ok, %{native: %{hold: :deferred}}} = DecisionStore.get(id, c.store)
  end

  test "replacement thread does not release an answered deferred Command", c do
    assert {:held, _, info} = Claude.handle(c.port, "request-1", params(), c.ctx)
    assert {:ok, %{decision: answered}} = DecisionStore.answer(info.decision_id, %{expected_version: 1, option_id: "o1", idempotency_key: "answer"}, [actor: %{kind: :operator, id: "human"}], c.store)
    assert answered.decision_status == :decided

    assert :ok = Claude.release_stale(%{thread_id: "replacement", store: c.store}, @ticket)
    assert {:ok, decision} = DecisionStore.get(info.decision_id, c.store)
    assert decision.native.hold == :deferred
    rows = File.read!(Path.join(c.dir, "decisions.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    refute Enum.any?(rows, &(&1["event_type"] == "native_released"))
  end

  test "lost reply transport releases Claude hold and restores the answer for ordinary delivery", c do
    assert {:held, ref, info} = Claude.handle(c.port, "request-1", params(), c.ctx)
    Port.close(c.port)
    owner = self()

    state = %{
      held_native_questions: %{ref => info},
      on_message: fn event -> send(owner, {:event, event}) end,
      on_native_reply: fn [^ref] -> {:reply, ref, %{"colour" => ["red"]}, fn _ -> flunk("lost session cannot deliver") end, fn reason -> send(owner, {:restore, reason}) end} end
    }

    assert %{held_native_questions: held} = NativeReplies.deliver(%{port: c.port, store: c.store, metadata: %{}}, state)
    assert held == %{}
    assert_received {:restore, :port_closed}
    assert_received {:event, %{reason: :session_gone}}
    assert_released(c, info.decision_id, :session_gone)
  end

  defp params, do: %{"itemId" => "tool-1", "questions" => [%{"id" => "colour", "header" => "Colour", "question" => "Which colour?", "options" => [%{"label" => "red"}, %{"label" => "blue"}]}]}

  defp assert_turn_starts(c, store) do
    port = c.port
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "next"}}})}}})
    assert {:ok, "next"} = CodingAgent.start_turn(%{port: port, thread_id: "replacement", workspace: c.dir, store: store}, "continue", @ticket)
    assert {^port, {:data, line}} = receive_barrier({^port, {:data, _}})
    assert %{"method" => "turn/start", "params" => %{"threadId" => "replacement"}} = Jason.decode!(line)
  end

  defp store_probe(decisions) do
    owner = self()
    pid = spawn(fn -> store_probe_loop(owner, decisions) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp store_probe_loop(owner, decisions) do
    receive do
      {:"$gen_call", from, request} ->
        send(owner, {:store_call, request})
        GenServer.reply(from, if(request == :list, do: decisions, else: {:error, :store_read_only}))
        store_probe_loop(owner, decisions)
    end
  end

  defp assert_released(c, id, reason) do
    # Capture and release both publish version 1; read after the release writer exits.
    await_release(c, id)
    assert {:ok, decision} = DecisionStore.get(id, c.store)
    assert decision.native.hold == :released
    assert decision.decision_status == :open
    assert decision.answer == nil
    rows = File.read!(Path.join(c.dir, "decisions.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.any?(rows, &(&1["event_type"] == "native_released" and &1["data"]["reason"] == Atom.to_string(reason)))
  end

  defp await_release(c, id) do
    case DecisionStore.get(id, c.store) do
      {:ok, %{native: %{hold: :released}}} ->
        :ok

      _ ->
        receive_barrier({:decision_changed, ^id, 1})
        await_release(c, id)
    end
  end
end
