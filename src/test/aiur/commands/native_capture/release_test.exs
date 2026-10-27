Code.require_file("../../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.NativeCapture.ReleaseTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.AppServer.{Interrupts, TurnLoop}
  alias Aiur.Codex.TurnLoopTestSupport
  alias Aiur.Commands.EventData
  alias Aiur.Commands.NativeCapture
  alias Aiur.Commands.NativeCapture.Release
  alias Aiur.DecisionDispatch
  alias Aiur.Events.Publisher

  defmodule Backend do
    def send_frame(_port, frame) do
      send(self(), {:frame, frame})
      :ok
    end

    def metadata_from_message(_port, _payload), do: %{}
    def handle_method(_session, state, %{"method" => "done"}, _raw, _method), do: {:ok, state}
  end

  setup %{dir: dir} do
    key = {Publisher, :tracked_fn}
    previous = :persistent_term.get(key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> :persistent_term.put(key, previous) end)
    store = start_store!(dir, dispatch_delay_ms: 60_000)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)

    normalized = %{
      harness: :codex,
      native_ref: "codex:thread-1:turn-1:7",
      turn_id: "turn-1",
      questions: Enum.map(["colour", "size"], &%{question_id: &1, question: "Choose #{&1}", options: [%{label: "Red"}, %{label: "Blue"}]})
    }

    assert {:command, decision} = NativeCapture.capture(normalized, %{ticket: @ticket, source: @source, store: store})
    :ok = DecisionPubSub.subscribe()
    owner = self()
    info = %{decision_id: decision.decision_id, native_ref: normalized.native_ref, question_ids: ["colour", "size"], request_id: 7}

    state =
      TurnLoopTestSupport.base_state()
      |> Map.merge(%{
        backend: Backend,
        held_native_questions: %{info.native_ref => info},
        native_release_store: store,
        on_message: fn msg -> send(owner, {:update, msg}) end,
        pending_line: "",
        timeout_ms: 0
      })

    port = TurnLoopTestSupport.open_cat_port()
    on_exit(fn -> TurnLoopTestSupport.close_port(port) end)
    %{state: state, store: store, id: decision.decision_id, session: %{port: port, thread_id: "thread-1", store: store}}
  end

  test "release answers every question, clears holders and durably leaves Command open", c do
    next = Release.release(c.session, c.state, :idle_timeout)
    assert next.held_native_questions == %{}
    assert_received {:frame, %{"id" => 7, "result" => %{"answers" => answers}}}
    text = NativeCapture.release_text(c.id)
    assert answers == Map.new(["colour", "size"], &{&1, %{"answers" => [text]}})
    assert_received {:update, %{event: :native_question_resolved, reason: :idle_timeout}}
    assert_released(c, :idle_timeout)
    assert {:ok, %{status: :duplicate}} = DecisionStore.record_command_fact(c.id, :native_released, %{native_ref: "codex:thread-1:turn-1:7", reason: :pause, at: DateTime.utc_now()}, server: c.store)
    GenServer.stop(c.store)
    replay = start_store!(c.dir, dispatch_delay_ms: 60_000)
    assert {:ok, restored} = DecisionStore.get(c.id, replay)
    assert restored.native.hold == :released
    assert restored.decision_status == :open
    GenServer.stop(replay)
  end

  test "first idle expiry releases and continues; next expiry returns timeout", c do
    owner = self()
    # The release callback queues completion, proving a second receive cycle runs.
    state = %{
      c.state
      | on_message: fn msg ->
          send(owner, {:update, msg})
          send(owner, {c.session.port, {:data, {:eol, ~s({"method":"done"})}}})
        end
    }

    assert {:ok, next} = TurnLoop.receive_loop(c.session, state)
    assert next.held_native_questions == %{}
    assert_released(c, :idle_timeout)
    assert {:error, :turn_timeout} = TurnLoop.receive_loop(c.session, %{next | timeout_ms: 0})
  end

  test "pause releases before sending interrupt", c do
    assert {:continue, next} = Interrupts.handle_pause_request(c.session, c.state, 23)
    assert next.held_native_questions == %{}
    assert next.pause_request_id == 23
    frames = for {:frame, frame} <- drain_frames(), do: frame
    assert [%{"id" => 7, "result" => _}, %{"method" => "turn/interrupt"}] = frames
    assert_released(c, :pause)
  end

  test "operator interrupt releases before cancelling the turn", c do
    assert {:continue, next} = Interrupts.handle_operator_queue_update(c.session, c.state)
    assert next.held_native_questions == %{}
    assert next.interrupt_action == :operator_message
    assert [{:frame, %{"id" => 7}}, {:frame, %{"method" => "turn/interrupt"}}] = drain_frames()
    assert_released(c, :interrupt)
  end

  test "port exit records session_gone without writing", c do
    send(self(), {c.session.port, {:exit_status, 9}})
    assert {:error, {:port_exit, 9}} = TurnLoop.receive_loop(c.session, c.state)
    refute_received {:frame, _}
    assert_received {:update, %{reason: :session_gone}}
    assert_released(c, :session_gone)
  end

  test "exit zero releases before returning a pending anonymous completion", c do
    state = Map.put(c.state, :pending_anonymous_completion?, true)
    send(self(), {c.session.port, {:exit_status, 0}})
    assert {:ok, :turn_completed} = TurnLoop.receive_loop(c.session, state)
    assert_received {:update, %{reason: :session_gone}}
    refute_received {:frame, _}
    assert_released(c, :session_gone)
  end

  test "DOWN records session_gone without writing", c do
    send(self(), {:DOWN, make_ref(), :port, c.session.port, :closed})
    assert {:error, {:port_exit, :closed}} = TurnLoop.receive_loop(c.session, c.state)
    assert_received {:update, %{reason: :session_gone}}
    refute_received {:frame, _}
    assert_released(c, :session_gone)
  end

  test "a stalled store never blocks the release response", c do
    :ok = :sys.suspend(c.store)

    try do
      assert %{held_native_questions: held} = Release.release(c.session, c.state, :pause)
      assert held == %{}
      assert_received {:frame, %{"id" => 7}}
    after
      :sys.resume(c.store)
    end

    assert_released(c, :pause)
  end

  test "closed transport write becomes session_gone", c do
    next = Release.release_all(c.state, :pause, fn _frame -> {:error, :port_closed} end)
    assert next.held_native_questions == %{}
    assert_received {:update, %{reason: :session_gone}}
    assert_released(c, :session_gone)
  end

  for method <- ["turn/failed", "turn/cancelled", "turn/completed"] do
    test "#{method} releases held questions", c do
      method = unquote(method)
      payload = if method == "turn/completed", do: TurnLoopTestSupport.turn_completed_payload("turn-1"), else: %{"method" => method, "params" => %{}}
      Aiur.Codex.TurnLoop.handle_method(c.session, c.state, payload, Jason.encode!(payload), method)
      assert_received {:frame, %{"id" => 7, "result" => _}}
      assert_released(c, :turn_ended)
    end
  end

  test "future regression guard: late completion of a previous turn leaves the current holder intact", c do
    payload = TurnLoopTestSupport.turn_completed_payload("old-turn")
    assert {:continue, next} = Aiur.Codex.TurnLoop.handle_method(c.session, c.state, payload, Jason.encode!(payload), "turn/completed")
    assert next.held_native_questions == c.state.held_native_questions
    refute_received {:frame, _}
  end

  test "idle-only completion releases a held question", c do
    state = %{c.state | turn_started?: true}
    payload = %{"method" => "thread/status/changed", "params" => %{"status" => %{"type" => "idle"}}}
    assert {:ok, :turn_completed} = Aiur.Codex.TurnLoop.handle_method(c.session, state, payload, Jason.encode!(payload), payload["method"])
    assert_received {:frame, %{"id" => 7}}
    assert_released(c, :turn_ended)
  end

  test "late top-level completion leaves current holder intact", c do
    payload = %{"method" => "turn/completed", "turn" => %{"id" => "old-turn", "status" => "completed"}}
    assert {:continue, next} = Aiur.Codex.TurnLoop.handle_method(c.session, c.state, payload, Jason.encode!(payload), "turn/completed")
    assert next.held_native_questions == c.state.held_native_questions
    refute_received {:frame, _}
  end

  test "interrupt acknowledgement releases a question captured after interrupt", c do
    state = %{c.state | pending_interrupt_request_id: 42, timeout_ms: 0}
    send(self(), {c.session.port, {:data, {:eol, ~s({"id":42,"result":{}})}}})
    assert {:error, :turn_timeout} = TurnLoop.receive_loop(c.session, state)
    assert_received {:update, %{reason: :interrupt}}
    assert_received {:frame, %{"id" => 7}}
    assert_released(c, :interrupt)
  end

  test "store rejection is logged while protocol release completes", c do
    owner = self()

    store =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:"$gen_call", from, {:command_fact, _id, :native_released, _data, _opts}} ->
               GenServer.reply(from, {:error, :read_only})
               send(owner, {:writer, elem(from, 0)})
           end
         end}
      )

    log =
      capture_log(fn ->
        assert %{held_native_questions: held} =
                 Release.release_all(%{c.state | native_release_store: store}, :pause, fn frame ->
                   send(owner, {:frame, frame})
                   :ok
                 end)

        assert held == %{}
        {:writer, writer} = receive_barrier({:writer, _})
        monitor = Process.monitor(writer)
        receive_barrier({:DOWN, ^monitor, :process, ^writer, _})
      end)

    assert log =~ "phase=record_failed"
    assert log =~ "decision_id=#{c.id}"
    assert_received {:frame, %{"id" => 7}}
    assert {:ok, unchanged} = DecisionStore.get(c.id, c.store)
    assert unchanged.native.hold == :in_band
    assert unchanged.decision_status == :open
  end

  test "answer after release uses the correlated message path", c do
    Release.release(c.session, c.state, :idle_timeout)
    assert_released(c, :idle_timeout)
    assert [{:frame, %{"id" => 7}}] = drain_frames()
    assert {:ok, %{decision: answered}} = DecisionStore.answer(c.id, %{expected_version: 1, option_id: "o1", idempotency_key: "after-release"}, [actor: %{kind: :operator, id: "operator-1"}], c.store)
    owner = self()

    assert {:ok, %{status: :accepted}} =
             DecisionDispatch.dispatch(answered,
               attempt_id: "after-release",
               send_fun: fn _server, ticket, payload ->
                 send(owner, {:message, ticket, payload})
                 {:ok, %{status: :accepted}}
               end
             )

    assert_received {:message, "979", %{kind: :text, body: body, correlation: %{decision_id: id}}}
    assert id == c.id
    assert body =~ "Red"
    refute_received {:frame, _}
  end

  test "release fact rejects invalid reasons, timestamps and mismatched native refs", c do
    data = %{native_ref: "other", reason: :pause, at: DateTime.utc_now()}
    assert {:error, {:invalid_transition, :native_ref_mismatch}} = DecisionStore.record_command_fact(c.id, :native_released, data, server: c.store)
    assert {:error, {:reason, :invalid_enum}} = EventData.normalize(:native_released, %{data | reason: :unknown})
    assert {:error, {:at, :invalid_timestamp}} = EventData.normalize(:native_released, %{data | at: "invalid"})
  end

  defp assert_released(c, reason) do
    id = c.id

    receive_barrier({:decision_changed, ^id, 1})

    assert {:ok, decision} = DecisionStore.get(c.id, c.store)
    assert decision.native.hold == :released
    assert decision.decision_status == :open
    assert decision.answer == nil
    events = File.read!(Path.join(c.dir, "decisions.ndjson")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [%{"data" => data}] = Enum.filter(events, &(&1["event_type"] == "native_released"))
    assert data["reason"] == Atom.to_string(reason)
  end

  defp drain_frames do
    receive do
      {:frame, _} = frame -> [frame | drain_frames()]
    after
      0 -> []
    end
  end
end
