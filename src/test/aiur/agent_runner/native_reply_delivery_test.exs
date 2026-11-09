Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.AgentRunner.NativeReplyDeliveryTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.AgentRunner.CheckpointDelivery
  alias Aiur.AppServer.{Interrupts, NativeReplies}
  alias Aiur.Commands.{Answering, NativeAnswer, NativeCapture}
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionDispatch
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.OperatorMessages.Calls

  # Exercise the production queue transitions with a private queue owner.
  defmodule QueueOwner do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, {owner, %Aiur.Orchestrator.State{}}}
    @impl true
    def handle_call({:enqueue, identifier, payload}, _from, {owner, state}) do
      {store, item} =
        Aiur.AgentQueueStore.enqueue(state.queue_store, %{
          target_issue_identifier: identifier,
          source: :operator,
          category: :operator_message,
          event_type: :operator_message,
          body: %{text: payload.body},
          action_id: payload.action_id,
          correlation: payload.correlation
        })

      send(owner, {:queued, item})
      {:reply, {:ok, %{status: :accepted, item: item}}, {owner, %{state | queue_store: store}}}
    end

    def handle_call({:claim_native_reply_item, identifier, refs}, _from, {owner, state}),
      do: wrap(Calls.claim_native_reply_item_call(state, identifier, refs), owner)

    def handle_call({:claim_next_queue_item, identifier}, _from, {owner, state}),
      do: wrap(Calls.claim_next_queue_item_call(state, identifier), owner)

    def handle_call({:restore_queue_item_pending, id}, _from, {owner, state}),
      do: wrap(Calls.restore_queue_item_pending_call(state, id), owner)

    def handle_call({:mark_queue_item_failed, id, reason}, _from, {owner, state}),
      do: wrap(Calls.mark_queue_item_failed_call(state, id, reason), owner)

    def handle_call({:acknowledge_queue_item_delivery, id, metadata}, _from, {owner, state}),
      do: wrap(Calls.acknowledge_queue_item_delivery_call(state, id, metadata), owner)

    def handle_call({:item, id}, _from, {owner, state}),
      do: {:reply, Aiur.AgentQueueStore.get(state.queue_store, id), {owner, state}}

    defp wrap({:reply, reply, state}, owner), do: {:reply, reply, {owner, state}}
  end

  setup %{dir: dir} do
    queue = start_supervised!({QueueOwner, self()})

    dispatcher = fn decision, opts ->
      opts = Keyword.put(opts, :revalidate_fun, fn issue, _, _ -> {:ok, issue} end)

      DecisionDispatch.dispatch(
        decision,
        Keyword.put(opts, :send_fun, fn _, identifier, payload ->
          GenServer.call(queue, {:enqueue, identifier, payload})
        end)
      )
    end

    store = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 60_000)
    on_exit(fn -> Aiur.TestSupport.safe_stop(store) end)
    owner = self()
    port = Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [:binary, :exit_status])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    %{store: store, queue: queue, port: port, on_message: fn msg -> send(owner, {:event, msg}) end}
  end

  test "in-band answer writes exact structured frame and records durable delivered evidence", c do
    d = capture(c)
    answer!(c, d)
    assert {:queued, item} = receive_barrier({:queued, _item})
    assert item.correlation.native_ref == "ref-1"
    assert item.correlation.question_answers == %{"colour" => ["red"]}
    assert {:continue, next} = Interrupts.handle_operator_queue_update(session(c), state(c, d))
    assert next.held_native_questions == %{}
    assert_frame(c, %{"colour" => %{"answers" => ["red"]}})
    assert_received {:event, %{event: :native_question_resolved, native_ref: "ref-1", reason: :answered}}
    assert {:ok, delivered} = DecisionStore.get(d.decision_id, c.store)
    assert delivered.delivery_status == :delivered
    assert Aiur.Decision.delivered?(delivered)
    recorded = GenServer.call(c.queue, {:item, item.id})
    assert %DateTime{} = recorded.provider_delivered_at
    assert :none = CheckpointDelivery.native_reply_handler(%Issue{identifier: "979"}, c.queue, c.store).(["ref-1"])
  end

  test "unrelated items stay pending while held and released answers use readable normal delivery", c do
    d = capture(c)
    answer!(c, d)
    assert {:queued, item} = receive_barrier({:queued, _item})
    held = state(c, d) |> Map.put(:held_native_questions, %{"other-ref" => %{request_id: 55}})
    assert ^held = NativeReplies.deliver(session(c), held)
    assert GenServer.call(c.queue, {:item, item.id}).status == :pending
    refute_received {_, {:data, _}}
    assert {:ok, fallback} = OperatorMessages.claim_next_queue_item(c.queue, "979")
    assert fallback.id == item.id
    assert fallback.body.text =~ "Which colour?: red"
  end

  test "closed port restores the claimed item without resolving the held question", c do
    d = capture(c)
    answer!(c, d)
    assert {:queued, item} = receive_barrier({:queued, _item})
    Port.close(c.port)
    held = state(c, d)
    assert ^held = NativeReplies.deliver(session(c), held)
    restored = GenServer.call(c.queue, {:item, item.id})
    assert restored.status == :pending
    assert restored.delivery_attempts == 1
    refute_received {:event, %{event: :native_question_resolved}}
    assert {:ok, current} = DecisionStore.get(d.decision_id, c.store)
    refute Aiur.Decision.delivered?(current)
  end

  test "a superseded queued answer is refused before writing and only the current action replies", c do
    d = capture(c)
    answer!(c, d)
    assert {:queued, first} = receive_barrier({:queued, _item})
    assert %{status: :accepted} = Answering.supersede(d.decision_id, %{expected_version: 1, idempotency_key: "replacement", rationale: "Choose blue instead", option_id: "o2"}, answer_opts(c))
    assert {:queued, second} = receive_barrier({:queued, _item})
    held = state(c, d)
    assert {:continue, next} = Interrupts.handle_operator_queue_update(session(c), held)
    assert GenServer.call(c.queue, {:item, first.id}).status == :failed
    assert next.held_native_questions == %{}
    assert_frame(c, %{"colour" => %{"answers" => ["blue"]}})
    assert GenServer.call(c.queue, {:item, second.id}).provider_delivered_at != nil
  end

  test "multi-select and Other values reach every question in the exact reply", c do
    d = capture(c, [question("colour", true), question("other", false)])
    answers = %{"colour" => ["red", "blue"], "other" => ["a custom value"]}
    assert %{status: :accepted} = Answering.answer(d.decision_id, %{expected_version: 1, idempotency_key: "multi", question_answers: answers}, answer_opts(c))
    assert {:queued, _item} = receive_barrier({:queued, _item})
    assert {:continue, next} = Interrupts.handle_operator_queue_update(session(c), state(c, d))
    assert next.held_native_questions == %{}
    assert_frame(c, Map.new(answers, fn {id, values} -> {id, %{"answers" => values}} end))
  end

  test "the canonical store rejects incomplete multi-question answers before dispatch", c do
    d = capture(c, [question("colour", true), question("other", false)])

    assert {:error, {:answer_invalid, {:question_answers, :incomplete}}} =
             DecisionStore.answer(d.decision_id, %{expected_version: 1, idempotency_key: "partial", option_id: "o1"}, [actor: %{kind: :operator, id: "human"}], c.store)

    assert {:ok, current} = DecisionStore.get(d.decision_id, c.store)
    assert current.answer == nil
    assert current.decision_status == :open
    refute_received {:queued, _}
  end

  test "retained legacy partial answers render safely and never claim a native reply", c do
    d = capture(c, [question("colour", true), question("other", false)])

    assert {:ok, answer} =
             DecisionAnswer.normalize(
               %{expected_version: 1, idempotency_key: "historical", option_id: "o1"},
               decision_id: d.decision_id,
               decision_version: 1,
               options: d.options,
               actor: %{kind: :operator, id: "human"},
               now: DateTime.utc_now()
             )

    retained = %{d | answer: answer, decision_status: :decided}
    assert DecisionDispatch.render(retained) =~ "Selected option `o1`: red"
    assert NativeAnswer.correlate(retained, answer, %{action_id: answer.action_id}) == %{action_id: answer.action_id}
  end

  defp capture(c, questions \\ [question("colour", false)]) do
    assert {:command, d} =
             NativeCapture.capture(
               %{
                 harness: :codex,
                 native_ref: "ref-1",
                 call_id: "call-1",
                 turn_id: "turn-1",
                 blocking: true,
                 questions: questions
               },
               %{ticket: @ticket, source: @source, session_ref: "session-1", store: c.store}
             )

    d
  end

  defp question(id, multi),
    do: %{
      question_id: id,
      header: "Colour",
      question: "Which colour?",
      options: [%{label: "red"}, %{label: "blue"}],
      multi_select: multi,
      allow_other: true,
      secret: false
    }

  defp answer!(c, d) do
    assert %{status: :accepted} = Answering.answer(d.decision_id, %{expected_version: 1, idempotency_key: "initial", option_id: "o1"}, answer_opts(c))
  end

  defp answer_opts(c), do: [store: c.store, actor: %{kind: :operator, id: "human"}, actor_source: :dashboard]
  defp session(c), do: %{port: c.port, metadata: %{}}

  defp state(c, d),
    do: %{
      held_native_questions: %{"ref-1" => %{request_id: 17, decision_id: d.decision_id}},
      on_message: c.on_message,
      on_native_reply: CheckpointDelivery.native_reply_handler(%Issue{identifier: "979"}, c.queue, c.store)
    }

  defp assert_frame(c, answers) do
    port = c.port
    assert {^port, {:data, line}} = receive_barrier({^port, {:data, _line}})
    assert Jason.decode!(line) == %{"id" => 17, "result" => %{"answers" => answers}}
  end
end
