defmodule Aiur.AgentRunner.CheckpointDelivery do
  @moduledoc """
  Mid-turn checkpoint delivery and immediate Executor delivery handlers.

  Delivers blocker-critical events urgently at safe-checkpoint boundaries,
  falls back to the next normal checkpoint item, and handles the four
  delivery-failure outcomes (restore vs. mark-failed) per FI-ORC-075.
  """

  require Logger

  alias Aiur.AgentRunner.{EventsDigest, MessageHandler, QueueDrain}
  alias Aiur.Issue

  # Mid-turn delivery for the persistent-REPL backend: when an Executor
  # message lands while the agent is working, the driver invokes this to
  # claim the next Executor item and type it straight into the live pane.
  # The claimed item moves to `delivered`, so the turn-end
  # `consume_delivered_queue_items` sweep retires it — it is never also run
  # as a separate follow-up turn. A send failure restores it to pending so
  # the normal turn-boundary drain re-attempts.
  @doc false
  @spec operator_immediate_handler(Issue.t(), GenServer.server(), GenServer.server(), keyword()) :: fun()
  def operator_immediate_handler(issue, orchestrator, decision_store \\ Aiur.DecisionStore, live_opts \\ []) do
    fn ->
      case QueueDrain.claim_next_operator_item(orchestrator, issue.identifier) do
        {:ok, item} ->
          immediate_operator_delivery(issue, orchestrator, item, decision_store, live_opts)

        :empty ->
          :noop
      end
    end
  end

  defp immediate_operator_delivery(issue, orchestrator, item, decision_store, live_opts) do
    case QueueDrain.prepare_operator_delivery(item, issue, decision_store) do
      :ok ->
        text = QueueDrain.queue_item_text(item)
        on_success = operator_delivery_success(orchestrator, item, issue, decision_store, live_opts)
        on_failure = fn _reason -> Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item.id) end
        {:deliver_text, text, on_success, on_failure}

      {:error, outcome} ->
        QueueDrain.settle_operator_delivery_failure(orchestrator, item, outcome)
        :noop
    end
  end

  @doc false
  @spec safe_checkpoint_handler(Issue.t(), GenServer.server(), GenServer.server(), keyword()) :: fun()
  def safe_checkpoint_handler(issue, orchestrator, decision_store \\ Aiur.DecisionStore, live_opts \\ []) do
    fn checkpoint ->
      case claim_blocker_critical_events_digest(orchestrator, issue.identifier) do
        {:ok, item} ->
          urgent_checkpoint_delivery(issue, orchestrator, item, checkpoint, decision_store)

        :empty ->
          fallback_checkpoint_claim(issue, orchestrator, checkpoint, decision_store, live_opts)
      end
    end
  end

  defp fallback_checkpoint_claim(issue, orchestrator, checkpoint, decision_store, live_opts) do
    case claim_next_checkpoint_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        safe_checkpoint_delivery(issue, orchestrator, item, checkpoint, decision_store, live_opts)

      :empty ->
        :noop
    end
  end

  defp urgent_checkpoint_delivery(issue, orchestrator, item, checkpoint, decision_store) do
    Logger.info("Urgent blocker-critical events delivered mid-turn for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} checkpoint=#{inspect(checkpoint)}")

    case QueueDrain.prepare_operator_delivery(item, issue, decision_store) do
      :ok ->
        text = render_urgent_events_digest(item)

        {:deliver_text, text, provider_delivery_callback(orchestrator, item, issue, decision_store),
         fn reason ->
           handle_checkpoint_delivery_failure(issue, orchestrator, item.id, reason)
         end}

      {:error, outcome} ->
        QueueDrain.settle_operator_delivery_failure(orchestrator, item, outcome)
        :noop
    end
  end

  # Reuse the renderer infrastructure but with the urgent="true" attribute.
  defp render_urgent_events_digest(%{body: %{events: events}} = item) do
    rendered = EventsDigest.render(events, Map.get(item, :target_issue_identifier))
    String.replace(rendered, "<aiur:events>", "<aiur:events urgent=\"true\">", global: false)
  end

  defp render_urgent_events_digest(item), do: QueueDrain.queue_item_text(item)

  defp claim_blocker_critical_events_digest(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_blocker_critical_events_digest(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp claim_next_checkpoint_queue_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_checkpoint_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp safe_checkpoint_delivery(issue, orchestrator, item, checkpoint, decision_store, live_opts) do
    Logger.info("Queueing Executor message into active turn for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} checkpoint=#{inspect(checkpoint)}")

    case QueueDrain.prepare_operator_delivery(item, issue, decision_store) do
      :ok ->
        text = QueueDrain.queue_item_text(item)
        on_success = operator_delivery_success(orchestrator, item, issue, decision_store, live_opts)
        on_failure = fn reason -> handle_checkpoint_delivery_failure(issue, orchestrator, item.id, reason) end
        {:deliver_text, text, on_success, on_failure}

      {:error, outcome} ->
        QueueDrain.settle_operator_delivery_failure(orchestrator, item, outcome)
        :noop
    end
  end

  defp handle_checkpoint_delivery_failure(issue, orchestrator, item_id, :parent_turn_completed) do
    Logger.info("Queued item delivery lost completion race for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item_id} decision=requeue_after_parent_turn_completed")
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(_issue, orchestrator, item_id, {:turn_interrupted, _payload}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(_issue, orchestrator, item_id, {:turn_cancelled, _payload}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(_issue, orchestrator, item_id, {:provider_turn_retired, _turn_id}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  # Provider `active turn` rejection (JSON-RPC -32003). Defensive parity with the
  # turn-boundary drain: the single-writer guard already stops the safe-checkpoint
  # path from sending a `turn/start` during a live parent turn, so this clause is a
  # belt-and-suspenders net. If a checkpoint delivery ever does reach the provider
  # and is rejected as active, the durable item is restored to pending — never
  # marked failed or dropped.
  defp handle_checkpoint_delivery_failure(issue, orchestrator, item_id, {:response_error, %{"code" => -32003}}) do
    Logger.info("Queued item delivery hit provider active turn for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item_id} decision=restore_pending reason=active_turn")
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  end

  defp handle_checkpoint_delivery_failure(issue, orchestrator, item_id, reason) do
    Logger.info("Queued item delivery failed for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item_id} decision=mark_failed reason=#{inspect(reason)}")
    Aiur.Orchestrator.mark_queue_item_failed(orchestrator, item_id, reason)
  end

  # Compose provider-delivery settlement (record + acknowledge) with the
  # DASH-026 live-conversation observation so an operator message that lands
  # mid-turn is both settled and projected into the bounded live conversation.
  defp operator_delivery_success(orchestrator, item, issue, decision_store, live_opts) do
    provider_callback = provider_delivery_callback(orchestrator, item, issue, decision_store)

    fn provider_metadata ->
      provider_callback.(provider_metadata)
      observe_operator_delivery(issue, item, live_opts)
    end
  end

  defp provider_delivery_callback(orchestrator, item, issue, decision_store) do
    fn provider_metadata ->
      :ok = QueueDrain.record_provider_delivery(item, issue, decision_store)
      QueueDrain.acknowledge_provider_delivery(orchestrator, item, provider_metadata)
    end
  end

  defp observe_operator_delivery(issue, item, live_opts) do
    case Keyword.get(live_opts, :backend) do
      backend when is_binary(backend) -> MessageHandler.observe_operator_delivery(issue, item, backend, live_opts)
      _ -> :ok
    end
  end
end
