defmodule Aiur.AgentRunner.DeliveryCorrelation do
  @moduledoc false
  require Logger
  alias Aiur.Commands
  alias Aiur.Signal
  @max_delivery_correlation_attempts 3

  @doc false
  @spec prepare_operator_delivery(map(), map(), GenServer.server()) ::
          :ok | {:error, {:retry | :failed, term()}}
  def prepare_operator_delivery(item, issue, decision_store \\ Commands.default_store())

  def prepare_operator_delivery(
        %{category: :operator_message, id: request_id, action_id: action_id, correlation: correlation} = item,
        %{identifier: identifier},
        decision_store
      )
      when is_integer(request_id) and is_binary(identifier) and is_binary(action_id) and is_map(correlation) do
    case Commands.validate_delivery(item, decision_store) do
      {:ok, :accepted} ->
        resolve_delivery_correlation_attention(identifier, action_id)
        :ok

      {:ok, :ignored} ->
        correlation_delivery_failed(item, identifier, action_id, :decision_correlation_ignored)

      # The answer was mooted or replaced before it reached the agent (#2711).
      # This is a final verdict, not a correlation fault: the item is failed at
      # once, with no retry and no correlation alert, so it is never delivered.
      {:error, {:answer_withdrawn, why} = reason} ->
        Logger.info("Decision answer withdrawn before delivery issue=#{identifier} action_id=#{action_id} reason=#{why}")
        {:error, {:failed, reason}}

      {:error, reason} ->
        correlation_delivery_failed(item, identifier, action_id, reason)
    end
  end

  def prepare_operator_delivery(
        %{category: :operator_message, id: request_id},
        %{identifier: identifier},
        _decision_store
      )
      when is_integer(request_id) and is_binary(identifier) do
    :ok
  end

  def prepare_operator_delivery(_item, _issue, _decision_store), do: :ok

  @doc false
  @spec record_provider_delivery(map(), map(), GenServer.server()) :: :ok
  def record_provider_delivery(item, issue, decision_store \\ Commands.default_store())

  def record_provider_delivery(
        %{category: :operator_message, id: request_id, action_id: action_id, correlation: correlation} = item,
        %{identifier: identifier},
        decision_store
      )
      when is_integer(request_id) and is_binary(identifier) and is_binary(action_id) and is_map(correlation) do
    case Commands.record_delivery(item, decision_store) do
      {:ok, status} when status in [:accepted, :duplicate] ->
        resolve_delivery_correlation_attention(identifier, action_id)

      {:ok, :ignored} ->
        provider_delivery_correlation_failed(identifier, action_id, :decision_correlation_ignored)

      {:error, reason} ->
        provider_delivery_correlation_failed(identifier, action_id, reason)
    end

    :ok
  end

  def record_provider_delivery(_item, _issue, _decision_store), do: :ok

  @doc false
  @spec acknowledge_provider_delivery(GenServer.server(), map(), map()) ::
          :ok | {:error, term()}
  def acknowledge_provider_delivery(orchestrator, item, provider_metadata)
      when is_map(item) and is_map(provider_metadata) do
    item
    |> delivery_item_ids()
    |> Enum.reduce_while(:ok, fn item_id, :ok ->
      case Aiur.Orchestrator.acknowledge_queue_item_delivery(
             orchestrator,
             item_id,
             provider_metadata
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delivery_item_ids(%{id: item_id} = item) do
    delivery = Map.get(item, :delivery, %{})
    Map.get(delivery, :coalesced_item_ids, [item_id])
  end

  @doc false
  @spec settle_operator_delivery_failure(GenServer.server(), map(), {:retry | :failed, term()}) ::
          :ok | {:error, term()}
  def settle_operator_delivery_failure(orchestrator, item, {:retry, _reason}) do
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item.id)
  end

  def settle_operator_delivery_failure(orchestrator, item, {:failed, reason}) do
    Aiur.Orchestrator.mark_queue_item_failed(orchestrator, item.id, {:decision_correlation_failed, reason})
  end

  defp correlation_delivery_failed(item, identifier, action_id, reason) do
    attempt = Map.get(item, :delivery_attempts, 1)

    if attempt >= @max_delivery_correlation_attempts do
      delivery_correlation_exhausted(identifier, action_id, reason)
    else
      Logger.warning("Decision delivery correlation will retry issue=#{identifier} action_id=#{action_id} attempt=#{attempt} reason=#{inspect(reason)}")

      {:error, {:retry, reason}}
    end
  end

  defp delivery_correlation_exhausted(identifier, action_id, reason) do
    Logger.warning("Decision delivery correlation exhausted issue=#{identifier} action_id=#{action_id} reason=#{inspect(reason)}")

    _ =
      Signal.agent_alert(
        delivery_correlation_attention_topic(identifier, action_id),
        "Decision answer handoff could not be durably correlated after bounded retries.",
        issue: identifier,
        reason: "Decision action #{action_id} handoff correlation retries were exhausted; the queue item is failed and actionable.",
        needs_attention: true,
        severity: "warning"
      )

    {:error, {:failed, reason}}
  end

  defp provider_delivery_correlation_failed(identifier, action_id, reason) do
    Logger.warning("Provider delivery reached issue=#{identifier} action_id=#{action_id}, but durable decision evidence failed reason=#{inspect(reason)}")

    _ =
      Signal.agent_alert(
        delivery_correlation_attention_topic(identifier, action_id),
        "Provider received the decision answer, but its durable delivery evidence failed.",
        issue: identifier,
        reason: "Decision action #{action_id} reached the provider but could not be durably marked delivered: #{inspect(reason)}.",
        needs_attention: true,
        severity: "warning"
      )

    :ok
  end

  defp resolve_delivery_correlation_attention(identifier, action_id) do
    _ =
      Signal.agent_alert(
        delivery_correlation_attention_topic(identifier, action_id) <> ".resolved",
        "Decision answer handoff is durably correlated.",
        issue: identifier,
        reason: "Decision action #{action_id} handoff correlation recovered.",
        needs_attention: false,
        severity: "info"
      )

    :ok
  end

  defp delivery_correlation_attention_topic(identifier, action_id) do
    action_slug = String.replace(action_id, "_", "-")
    "ticket.#{identifier}.agent.attention.decision-delivery-correlation-#{action_slug}"
  end
end
