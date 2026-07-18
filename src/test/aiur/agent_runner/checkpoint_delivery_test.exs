defmodule Aiur.AgentRunner.CheckpointDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.CheckpointDelivery
  alias Aiur.{Issue, LiveConversation, TrackerIdentity}

  # Minimal fake orchestrator: answers the `claim_*` calls with canned
  # responses and forwards the `restore`/`mark_failed` failure-recovery calls
  # to the test process, so the four delivery-failure outcomes (FI-ORC-075)
  # can be asserted without standing up the full orchestrator GenServer.
  defmodule FakeOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         report: Keyword.fetch!(opts, :report),
         operator: Keyword.get(opts, :operator, :empty),
         blocker: Keyword.get(opts, :blocker, :empty),
         checkpoint: Keyword.get(opts, :checkpoint, :empty)
       }}
    end

    @impl true
    def handle_call({:claim_next_operator_queue_item, _id}, _from, state),
      do: {:reply, state.operator, state}

    def handle_call({:claim_blocker_critical_events_digest, _id}, _from, state),
      do: {:reply, state.blocker, state}

    def handle_call({:claim_next_checkpoint_queue_item, _id}, _from, state),
      do: {:reply, state.checkpoint, state}

    def handle_call({:restore_queue_item_pending, item_id}, _from, state) do
      send(state.report, {:restore, item_id})
      {:reply, :ok, state}
    end

    def handle_call({:mark_queue_item_failed, item_id, reason}, _from, state) do
      send(state.report, {:mark_failed, item_id, reason})
      {:reply, :ok, state}
    end

    def handle_call(
          {:acknowledge_queue_item_delivery, item_id, provider_metadata},
          _from,
          state
        ) do
      send(state.report, {:provider_delivered, item_id, provider_metadata})
      {:reply, :ok, state}
    end
  end

  defmodule FakeDecisionStore do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{report: Keyword.fetch!(opts, :report), reply: Keyword.fetch!(opts, :reply)}}

    @impl true
    def handle_call({:validate_delivery, item}, _from, state) do
      send(state.report, {:decision_delivery_prepared, item.id})
      {:reply, state.reply, state}
    end

    def handle_call({:transport_transition, :delivered, item, nil}, _from, state) do
      send(state.report, {:decision_delivery, item.id})
      {:reply, {:ok, :accepted}, state}
    end
  end

  defp start_fake(opts) do
    {:ok, pid} = FakeOrchestrator.start_link(Keyword.put(opts, :report, self()))
    pid
  end

  defp start_decision_store(reply) do
    {:ok, pid} = FakeDecisionStore.start_link(report: self(), reply: reply)
    pid
  end

  defp correlated_item(id) do
    %{
      category: :operator_message,
      id: id,
      body: %{text: "durable answer"},
      action_id: "act_#{id}",
      correlation: %{
        decision_id: "dec_#{id}",
        decision_version: 1,
        action_id: "act_#{id}",
        attempt_id: "act_#{id}:1"
      }
    }
  end

  defp issue, do: %Issue{identifier: "CD-#{System.unique_integer([:positive])}", id: "gid-cd"}

  describe "operator_immediate_handler/2" do
    test "returns a zero-arity function" do
      handler = CheckpointDelivery.operator_immediate_handler(issue(), self())
      assert is_function(handler, 0)
    end

    test "noops when the operator queue is empty" do
      orch = start_fake(operator: :empty)
      handler = CheckpointDelivery.operator_immediate_handler(issue(), orch)

      assert handler.() == :noop
    end

    test "delivers the claimed operator item and restores it to pending on send failure" do
      item = %{category: :operator_message, id: 5, body: %{text: "hello operator"}}
      orch = start_fake(operator: {:ok, item})
      handler = CheckpointDelivery.operator_immediate_handler(issue(), orch)

      assert {:deliver_text, "hello operator", success, failure} = handler.()
      assert is_function(success, 1)
      assert success.(%{turn_id: "turn-5"}) == :ok
      assert_receive {:provider_delivered, 5, %{turn_id: "turn-5"}}

      # A send failure restores the claimed item so the normal turn-boundary
      # drain re-attempts it.
      failure.(:send_failed)
      assert_receive {:restore, 5}
    end

    test "restores a correlated item instead of exposing text when durable handoff fails" do
      item = correlated_item(6)
      orch = start_fake(operator: {:ok, item})
      decision_store = start_decision_store({:error, :store_unavailable})
      handler = CheckpointDelivery.operator_immediate_handler(issue(), orch, decision_store)

      assert handler.() == :noop
      assert_receive {:decision_delivery_prepared, 6}
      refute_receive {:decision_delivery, 6}
      assert_receive {:restore, 6}
    end

    test "marks a correlated item failed after bounded handoff retries" do
      item = Map.put(correlated_item(7), :delivery_attempts, 3)
      orch = start_fake(operator: {:ok, item})
      decision_store = start_decision_store({:error, :store_unavailable})
      handler = CheckpointDelivery.operator_immediate_handler(issue(), orch, decision_store)

      assert handler.() == :noop
      assert_receive {:decision_delivery_prepared, 7}
      refute_receive {:decision_delivery, 7}
      assert_receive {:mark_failed, 7, {:decision_correlation_failed, :store_unavailable}}
      refute_receive {:restore, 7}, 100
    end

    test "projects immediate delivery only after provider success and exactly once" do
      {issue, source, live_opts} = live_context(41)
      item = %{category: :operator_message, id: 41, body: %{text: "immediate accepted"}}
      orch = start_fake(operator: {:ok, item})

      handler =
        CheckpointDelivery.operator_immediate_handler(
          issue,
          orch,
          Aiur.DecisionStore,
          live_opts
        )

      assert {:deliver_text, "immediate accepted", success, _failure} = handler.()
      assert %{state: :restart_unknown, messages: []} = snapshot(source, live_opts)

      assert :ok = success.(%{turn_id: "turn-accepted"})
      assert :ok = success.(%{turn_id: "turn-accepted"})

      assert %{messages: [%{role: "operator", body: "immediate accepted"}]} =
               snapshot(source, live_opts)
    end

    test "a failed immediate delivery projects no operator evidence" do
      {issue, source, live_opts} = live_context(42)
      item = %{category: :operator_message, id: 42, body: %{text: "immediate rejected"}}
      orch = start_fake(operator: {:ok, item})

      handler =
        CheckpointDelivery.operator_immediate_handler(
          issue,
          orch,
          Aiur.DecisionStore,
          live_opts
        )

      assert {:deliver_text, "immediate rejected", _success, failure} = handler.()
      assert :ok = failure.(:send_failed)
      assert_receive {:restore, 42}
      assert %{state: :restart_unknown, messages: []} = snapshot(source, live_opts)
    end
  end

  describe "safe_checkpoint_handler/2" do
    test "returns a one-arity function" do
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), self())
      assert is_function(handler, 1)
    end

    test "delivers a blocker-critical events digest with the urgent attribute" do
      event = %{id: 9, topic: "ticket.CD.agent.progress", message: "blocker critical text"}
      item = %{id: 7, body: %{events: [event]}, target_issue_identifier: "CD-DIGEST"}
      orch = start_fake(blocker: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, text, _success, failure} = handler.(%{safe: :checkpoint})
      assert text =~ ~s(<aiur:events urgent="true">)
      assert text =~ "blocker critical text"

      # A lost completion race requeues the digest as pending.
      failure.(:parent_turn_completed)
      assert_receive {:restore, 7}
    end

    test "urgent digest falls back to queue_item_text for an item carrying no events" do
      item = %{category: :operator_message, id: 11, body: %{text: "urgent operator text"}}
      orch = start_fake(blocker: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "urgent operator text", _s, _f} = handler.(:checkpoint)
    end

    test "a blocker claim error is treated as empty and falls through to the checkpoint queue" do
      item = %{category: :operator_message, id: 8, body: %{text: "checkpoint text"}}
      orch = start_fake(blocker: {:error, :unavailable}, checkpoint: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "checkpoint text", _s, failure} = handler.(:checkpoint)

      # {:turn_interrupted, _} restores the item to pending.
      failure.({:turn_interrupted, %{}})
      assert_receive {:restore, 8}
    end

    test "a turn-cancelled failure restores the checkpoint item to pending" do
      item = %{category: :operator_message, id: 21, body: %{text: "cp"}}
      orch = start_fake(checkpoint: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "cp", _s, failure} = handler.(:checkpoint)

      failure.({:turn_cancelled, %{}})
      assert_receive {:restore, 21}
    end

    test "a provider active-turn (-32_003) rejection restores the checkpoint item to pending" do
      item = %{category: :operator_message, id: 24, body: %{text: "cp"}}
      orch = start_fake(checkpoint: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "cp", _s, failure} = handler.(:checkpoint)

      # aiur-claude rejected a `turn/start` on an active thread; the durable
      # item must be restored to pending, never marked failed.
      failure.({:response_error, %{"code" => -32_003}})
      assert_receive {:restore, 24}
      refute_receive {:mark_failed, 24, _reason}
    end

    test "a late response for retired provider work restores the checkpoint item" do
      item = %{category: :operator_message, id: 23, body: %{text: "cp"}}
      orch = start_fake(checkpoint: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "cp", _success, failure} = handler.(:checkpoint)

      failure.({:provider_turn_retired, "turn-old"})
      assert_receive {:restore, 23}
    end

    test "keeps a correlated checkpoint queued until the provider callback" do
      item = correlated_item(22)
      orch = start_fake(checkpoint: {:ok, item})
      decision_store = start_decision_store({:ok, :accepted})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch, decision_store)

      assert {:deliver_text, "durable answer", success, _failure} = handler.(:checkpoint)
      assert_receive {:decision_delivery_prepared, 22}
      refute_receive {:decision_delivery, 22}

      assert success.(%{turn_id: "provider-22"}) == :ok
      assert_receive {:decision_delivery, 22}
      assert_receive {:provider_delivered, 22, %{turn_id: "provider-22"}}
    end

    test "an unrecognized delivery failure marks the checkpoint item failed" do
      item = %{category: :operator_message, id: 33, body: %{text: "cp"}}
      orch = start_fake(checkpoint: {:ok, item})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert {:deliver_text, "cp", _s, failure} = handler.(:checkpoint)

      failure.({:some_other, :boom})
      assert_receive {:mark_failed, 33, {:some_other, :boom}}
    end

    test "noops when both the blocker and checkpoint queues are empty" do
      orch = start_fake(blocker: :empty, checkpoint: :empty)
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert handler.(:checkpoint) == :noop
    end

    test "a checkpoint claim error is treated as empty (noop)" do
      orch = start_fake(blocker: :empty, checkpoint: {:error, :unavailable})
      handler = CheckpointDelivery.safe_checkpoint_handler(issue(), orch)

      assert handler.(:checkpoint) == :noop
    end

    test "projects checkpoint delivery only from its provider success callback" do
      {issue, source, live_opts} = live_context(51)
      item = %{category: :operator_message, id: 51, body: %{text: "checkpoint accepted"}}
      orch = start_fake(checkpoint: {:ok, item})

      handler =
        CheckpointDelivery.safe_checkpoint_handler(
          issue,
          orch,
          Aiur.DecisionStore,
          live_opts
        )

      assert {:deliver_text, "checkpoint accepted", success, _failure} =
               handler.(:checkpoint)

      assert %{state: :restart_unknown, messages: []} = snapshot(source, live_opts)
      assert :ok = success.(%{turn_id: "turn-accepted"})

      assert %{messages: [%{role: "operator", body: "checkpoint accepted"}]} =
               snapshot(source, live_opts)
    end

    test "a correlated handoff projects only after durable and provider acceptance" do
      {issue, source, live_opts} = live_context(52)

      item =
        52
        |> correlated_item()
        |> put_in([:body, :text], "durable accepted")

      orch = start_fake(checkpoint: {:ok, item})
      decision_store = start_decision_store({:ok, :accepted})

      handler =
        CheckpointDelivery.safe_checkpoint_handler(
          issue,
          orch,
          decision_store,
          live_opts
        )

      assert {:deliver_text, "durable accepted", success, _failure} =
               handler.(:checkpoint)

      assert_receive {:decision_delivery_prepared, 52}
      refute_receive {:decision_delivery, 52}
      assert %{state: :restart_unknown, messages: []} = snapshot(source, live_opts)

      assert :ok = success.(%{turn_id: "turn-accepted"})

      assert_receive {:decision_delivery, 52}

      assert %{messages: [%{role: "operator", body: "durable accepted"}]} =
               snapshot(source, live_opts)
    end

    test "a requeued checkpoint delivery projects nothing" do
      {issue, source, live_opts} = live_context(53)
      item = %{category: :operator_message, id: 53, body: %{text: "checkpoint requeued"}}
      orch = start_fake(checkpoint: {:ok, item})

      handler =
        CheckpointDelivery.safe_checkpoint_handler(
          issue,
          orch,
          Aiur.DecisionStore,
          live_opts
        )

      assert {:deliver_text, "checkpoint requeued", _success, failure} =
               handler.(:checkpoint)

      assert :ok = failure.({:provider_turn_retired, "retired"})
      assert_receive {:restore, 53}
      assert %{state: :restart_unknown, messages: []} = snapshot(source, live_opts)
    end
  end

  defp live_context(id) do
    unique = Integer.to_string(System.unique_integer([:positive]))
    server = start_supervised!({LiveConversation, name: nil})

    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "provider-#{unique}",
      identifier: unique,
      reason: nil
    }

    issue = %Issue{id: "gid-#{id}-#{unique}", identifier: unique, tracker_identity: identity}

    source = %{
      identity: identity,
      attempt_id: "attempt-#{unique}",
      backend: "codex",
      worker_generation: id
    }

    opts = [
      backend: "codex",
      attempt_id: "attempt-#{unique}",
      worker_generation: id,
      live_conversation_server: server
    ]

    {issue, source, opts}
  end

  defp snapshot(source, opts) do
    LiveConversation.snapshot(source, server: Keyword.fetch!(opts, :live_conversation_server))
  end
end
