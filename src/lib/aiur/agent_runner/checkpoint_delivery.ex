defmodule Aiur.AgentRunner.CheckpointDelivery do
  @moduledoc """
  Mid-turn checkpoint delivery and immediate operator delivery handlers.

  Delivers blocker-critical events urgently at safe-checkpoint boundaries,
  falls back to the next normal checkpoint item, and handles the four
  delivery-failure outcomes (restore vs. mark-failed) per FI-ORC-075.
  """

  require Logger

  alias Aiur.AgentRunner.{EventsDigest, QueueDrain}
  alias Aiur.Issue

  # Mid-turn delivery for the persistent-REPL backend: when an operator
  # message lands while the agent is working, the driver invokes this to
  # claim the next operator item and type it straight into the live pane.
  # The claimed item moves to `delivered`, so the turn-end
  # `consume_delivered_queue_items` sweep retires it — it is never also run
  # as a separate follow-up turn. A send failure restores it to pending so
  # the normal turn-boundary drain re-attempts.
  @doc false
  @spec operator_immediate_handler(Issue.t(), GenServer.server()) :: fun()
  def operator_immediate_handler(issue, orchestrator) do
    fn ->
      case QueueDrain.claim_next_operator_item(orchestrator, issue.identifier) do
        {:ok, item} ->
          immediate_operator_delivery(issue, orchestrator, item)

        :empty ->
          :noop
      end
    end
  end

  defp immediate_operator_delivery(issue, orchestrator, item) do
    QueueDrain.record_operator_delivery(item, issue)

    {:deliver_text, QueueDrain.queue_item_text(item), fn _payload -> :ok end, fn _reason -> Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item.id) end}
  end

  @doc false
  @spec safe_checkpoint_handler(Issue.t(), GenServer.server()) :: fun()
  def safe_checkpoint_handler(issue, orchestrator) do
    fn checkpoint ->
      case claim_blocker_critical_events_digest(orchestrator, issue.identifier) do
        {:ok, item} ->
          urgent_checkpoint_delivery(issue, orchestrator, item, checkpoint)

        :empty ->
          fallback_checkpoint_claim(issue, orchestrator, checkpoint)
      end
    end
  end

  defp fallback_checkpoint_claim(issue, orchestrator, checkpoint) do
    case claim_next_checkpoint_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        safe_checkpoint_delivery(issue, orchestrator, item, checkpoint)

      :empty ->
        :noop
    end
  end

  defp urgent_checkpoint_delivery(issue, orchestrator, item, checkpoint) do
    Logger.info("Urgent blocker-critical events delivered mid-turn for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} checkpoint=#{inspect(checkpoint)}")

    QueueDrain.record_operator_delivery(item, issue)

    text = render_urgent_events_digest(item)

    {:deliver_text, text, fn _payload -> :ok end, fn reason -> handle_checkpoint_delivery_failure(issue, orchestrator, item.id, reason) end}
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

  defp safe_checkpoint_delivery(issue, orchestrator, item, checkpoint) do
    Logger.info("Queueing operator message into active turn for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} checkpoint=#{inspect(checkpoint)}")

    QueueDrain.record_operator_delivery(item, issue)

    {:deliver_text, QueueDrain.queue_item_text(item), fn _payload -> :ok end,
     fn reason ->
       handle_checkpoint_delivery_failure(issue, orchestrator, item.id, reason)
     end}
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

  defp handle_checkpoint_delivery_failure(issue, orchestrator, item_id, reason) do
    Logger.info("Queued item delivery failed for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item_id} decision=mark_failed reason=#{inspect(reason)}")
    Aiur.Orchestrator.mark_queue_item_failed(orchestrator, item_id, reason)
  end
end
