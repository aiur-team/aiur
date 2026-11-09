defmodule AiurWeb.Conversation.DeliveryOverlay do
  @moduledoc "Local send observations reconciled against durable operator journal entries."

  alias Aiur.Listener

  @timeout_ms 600_000
  @pending [:accepted, :queued, :held_async]

  @type item :: %{
          client_id: String.t(),
          delivery_id: integer() | nil,
          text: String.t(),
          state: :accepted | :queued | :held_async | :unknown | :failed,
          reason: term(),
          started_at: integer(),
          updated_at: integer()
        }
  @type t :: %{optional(integer() | String.t()) => item()}

  @spec put_send(t(), String.t(), String.t(), term(), integer()) :: t()
  def put_send(overlay, client_id, text, result, now_ms) do
    {id, state, reason} = send_observation(result)
    previous = Enum.find_value(overlay, fn {_key, item} -> if item.client_id == client_id, do: item end)

    item = %{
      client_id: client_id,
      delivery_id: id,
      text: text,
      state: state,
      reason: reason,
      started_at: if(previous, do: previous.started_at, else: now_ms),
      updated_at: now_ms
    }

    overlay
    |> Map.reject(fn {_key, existing} -> existing.client_id == client_id end)
    |> Map.put(id || client_id, item)
  end

  @spec reconcile(t(), [map()]) :: t()
  def reconcile(overlay, entries) do
    ids =
      entries
      |> Enum.filter(&(Map.get(&1, :kind) == "operator_message"))
      |> Enum.map(&(Map.get(&1, :refs, %{}) |> Map.get(:delivery_id)))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&to_string/1)

    Map.reject(overlay, fn {_key, item} ->
      not is_nil(item.delivery_id) and MapSet.member?(ids, to_string(item.delivery_id))
    end)
  end

  @spec pending?(t()) :: boolean()
  def pending?(overlay), do: Enum.any?(overlay, fn {_id, item} -> item.state in @pending end)

  @spec poll(t(), (integer() -> term()), integer()) :: t()
  def poll(overlay, receipt_fun, now_ms) do
    Map.new(overlay, fn {id, item} ->
      updated = if item.state in @pending, do: observe(item, receipt_fun.(item.delivery_id), now_ms), else: item
      {id, updated}
    end)
  end

  defp send_observation(result) do
    case Listener.receipt_for_send_result(result) do
      :accepted ->
        {:ok, id} = result
        {id, :accepted, nil}

      :outcome_unknown ->
        {:error, {:outcome_unknown, info}} = result
        {Map.get(info, :item_id), :unknown, :outcome_unknown}

      :failed ->
        {:error, reason} = result
        {nil, :failed, reason}
    end
  end

  defp observe(item, {:ok, %{receipt: :failed} = receipt}, now_ms),
    do: update(item, :failed, Map.get(receipt, :failure_reason, :unknown), now_ms)

  defp observe(item, {:ok, %{receipt: :held_async}}, now_ms),
    do: update(item, :held_async, nil, now_ms)

  defp observe(item, {:ok, %{receipt: state}}, now_ms) when state in [:accepted, :harness_queued, :in_context, :read] do
    if now_ms - item.started_at >= @timeout_ms do
      update(item, :unknown, :journal_timeout, now_ms)
    else
      state = if state == :accepted, do: item.state, else: :queued
      update(item, state, nil, now_ms)
    end
  end

  defp observe(item, {:error, reason}, now_ms), do: update(item, :unknown, reason, now_ms)
  defp observe(item, _receipt, now_ms), do: update(item, :unknown, :receipt_unknown, now_ms)

  defp update(item, state, reason, now_ms), do: %{item | state: state, reason: reason, updated_at: now_ms}
end
