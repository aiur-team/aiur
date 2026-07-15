defmodule Aiur.AgentRunner.QueueDrainTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.{QueueDrain, ToolExecutor}
  alias Aiur.{AlertFeed, Issue, TrackerIdentity}
  alias Aiur.Events.Exchange

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    log_root = Path.join(System.tmp_dir!(), "aiur-queue-drain-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf!(log_root)
    end)

    %{log_root: log_root}
  end

  defmodule FakeDecisionStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{report: Keyword.fetch!(opts, :report), reply: Keyword.fetch!(opts, :reply)}}

    @impl true
    def handle_call({:transport_transition, :delivered, item, nil}, _from, state) do
      send(state.report, {:decision_delivery, item})
      {:reply, state.reply, state}
    end
  end

  defmodule FakeQueueOrchestrator do
    use GenServer

    def start_link(item, report), do: GenServer.start_link(__MODULE__, %{item: item, delivered: nil, report: report})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim_next_queue_item, _identifier}, _from, %{item: item} = state) when is_map(item) do
      {:reply, {:ok, item}, %{state | item: nil, delivered: item}}
    end

    def handle_call({:claim_next_queue_item, _identifier}, _from, state) do
      {:reply, :empty, state}
    end

    def handle_call({:consume_delivered_queue_items, identifier}, _from, state) do
      send(state.report, {:queue_item_consumed, identifier})
      {:reply, :ok, %{state | delivered: nil}}
    end

    def handle_call({:restore_delivered_queue_items, identifier}, _from, %{delivered: delivered} = state) do
      send(state.report, {:queue_item_restored, identifier})
      {:reply, :ok, %{state | item: delivered, delivered: nil}}
    end

    def handle_call({:fail_delivered_queue_items, identifier, reason}, _from, state) do
      send(state.report, {:queue_item_failed, identifier, reason})
      {:reply, :ok, %{state | delivered: nil}}
    end
  end

  defp correlated_item do
    %{
      category: :operator_message,
      id: 9,
      action_id: "act_9",
      correlation: %{
        decision_id: "dec_9",
        decision_version: 1,
        action_id: "act_9",
        attempt_id: "act_9:1"
      }
    }
  end

  describe "claim_after_queue_update/3" do
    test "returns :ignored when deliver_now? is false" do
      assert QueueDrain.claim_after_queue_update(self(), "QD-01", false) == :ignored
    end
  end

  describe "record_operator_delivery/2" do
    test "returns :ok for a non-operator-message item" do
      item = %{category: :coordination_event, id: 1}
      issue = %Issue{identifier: "QD-01", id: "gid-qd01"}

      assert QueueDrain.record_operator_delivery(item, issue) == :ok
    end

    test "returns :ok when issue has no binary identifier" do
      item = %{category: :operator_message, id: 1}
      issue = %Issue{identifier: nil, id: "gid-qd02"}

      assert QueueDrain.record_operator_delivery(item, issue) == :ok
    end

    test "persists correlated delivery before returning success" do
      {:ok, store} = FakeDecisionStore.start_link(report: self(), reply: {:ok, :accepted})
      issue = %Issue{identifier: "QD-09", id: "gid-qd09"}

      assert QueueDrain.record_operator_delivery(correlated_item(), issue, store) == :ok
      assert_receive {:decision_delivery, %{action_id: "act_9"}}
    end

    test "bounds correlation retries and keeps terminal attention open until recovery", %{log_root: log_root} do
      {:ok, store} = FakeDecisionStore.start_link(report: self(), reply: {:error, :store_unavailable})
      issue = %Issue{identifier: "QD-09", id: "gid-qd09"}
      topic = "ticket.QD-09.agent.attention.decision-delivery-correlation-act-9"

      assert QueueDrain.record_operator_delivery(correlated_item(), issue, store) ==
               {:error, {:retry, :store_unavailable}}

      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []

      exhausted = Map.put(correlated_item(), :delivery_attempts, 3)

      assert QueueDrain.record_operator_delivery(exhausted, issue, store) ==
               {:error, {:failed, :store_unavailable}}

      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      {:ok, recovered_store} = FakeDecisionStore.start_link(report: self(), reply: {:ok, :accepted})
      assert QueueDrain.record_operator_delivery(correlated_item(), issue, recovered_store) == :ok
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end
  end

  describe "queue_item_text/1" do
    test "extracts body text from an operator_message item" do
      item = %{category: :operator_message, body: %{text: "hello operator"}}

      assert QueueDrain.queue_item_text(item) == "hello operator"
    end

    test "renders an events_digest coordination event via EventsDigest" do
      event = %{id: 1, topic: "ticket.QD-01.agent.progress", message: "progress note"}
      item = %{category: :coordination_event, event_type: :events_digest, body: %{events: [event]}}

      result = QueueDrain.queue_item_text(item)

      assert result =~ "<aiur:events>"
      assert result =~ "progress note"
    end

    test "returns summary for other coordination events" do
      item = %{
        category: :coordination_event,
        event_type: :some_kind,
        body: %{summary: "coordination summary"}
      }

      result = QueueDrain.queue_item_text(item)

      assert result =~ "coordination summary"
      assert result =~ "some_kind"
    end

    test "falls back to inspect for unknown item shapes" do
      item = %{category: :unknown}

      result = QueueDrain.queue_item_text(item)

      assert is_binary(result)
    end
  end

  describe "drain_operator_messages/6" do
    test "queued turns preserve lifecycle attempts in emitted observations" do
      identifier = "QD-observation-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOQueueObservation", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      issue = %Issue{identifier: identifier, tracker_identity: identity}
      item = %{category: :operator_message, id: 1, body: %{text: "queued message"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.checkin")

      run_turn = fn _session, _text, _issue, opts ->
        executor = Keyword.fetch!(opts, :tool_executor)

        assert ToolExecutor.execute(
                 executor,
                 "emit_event",
                 %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 60}},
                 "queued-tool"
               )["success"] == true

        {:ok, %{session_id: "queued-session"}}
      end

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "queue-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 telemetry_attempt_id: 7,
                 run_turn: run_turn
               )

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert observation.tracker_identity == identity
      assert observation.provenance.attempt == 7
      assert observation.provenance.session_id == "queue-thread"
      assert observation.provenance.source_event_id == "queued-tool"
      assert_receive {:queue_item_consumed, ^identifier}
    end

    test "provider exits restore the queued message for a replacement to drain once" do
      identifier = "QD-port-closed-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 2, body: %{text: "retry on replacement"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:port_exit, 9}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "retired-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, {:port_exit, 9}} end
               )

      assert_receive {:queue_item_restored, ^identifier}
      refute_receive {:queue_item_consumed, ^identifier}
      refute_receive {:queue_item_failed, ^identifier, {:port_exit, 9}}

      test_pid = self()

      assert :ok =
               QueueDrain.drain_operator_messages(
                 %{backend: "codex", thread_id: "replacement-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn session, text, _issue, _opts ->
                   send(test_pid, {:replacement_turn, session.thread_id, text})
                   {:ok, session}
                 end
               )

      assert_receive {:replacement_turn, "replacement-thread", "retry on replacement"}
      refute_receive {:replacement_turn, "replacement-thread", "retry on replacement"}
      assert_receive {:queue_item_consumed, ^identifier}
      refute_receive {:queue_item_restored, ^identifier}
    end

    test "Claude provider exits retain the existing failed-delivery behavior" do
      identifier = "QD-claude-port-exit-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 3, body: %{text: "do not replay"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, {:port_exit, 9}} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", thread_id: "claude-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, {:port_exit, 9}} end
               )

      assert_receive {:queue_item_failed, ^identifier, {:port_exit, 9}}
      refute_receive {:queue_item_restored, ^identifier}
    end

    test "Claude closed ports retain the existing failed-delivery behavior" do
      identifier = "QD-claude-port-closed-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      item = %{category: :operator_message, id: 4, body: %{text: "do not replay"}}
      {:ok, orchestrator} = FakeQueueOrchestrator.start_link(item, self())

      assert {:error, :port_closed} =
               QueueDrain.drain_operator_messages(
                 %{backend: "claude", thread_id: "claude-thread"},
                 issue,
                 fn _message -> :ok end,
                 orchestrator,
                 nil,
                 run_turn: fn _session, _text, _issue, _opts -> {:error, :port_closed} end
               )

      assert_receive {:queue_item_failed, ^identifier, :port_closed}
      refute_receive {:queue_item_restored, ^identifier}
    end
  end
end
