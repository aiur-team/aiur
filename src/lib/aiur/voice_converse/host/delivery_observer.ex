defmodule Aiur.VoiceConverse.Host.DeliveryObserver do
  @moduledoc false
  use GenServer
  alias Aiur.VoiceConverse.Host.DeliveryReceipt

  @impl true
  def init({target, subscriber, opts}) do
    monitor = Process.monitor(subscriber)
    live = Keyword.get(opts, :live, Aiur.LiveConversation)
    if target.live_source, do: live.subscribe(target.live_source)
    {:ok, %{target: target, subscribers: %{subscriber => monitor}, live: live, opts: opts, items: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_cast({:send, ref, text, key, kind}, state) do
    case Map.get(state.items, ref) do
      nil ->
        {:noreply, enqueue(state, ref, text, key, kind)}

      %{text: ^text} ->
        {:noreply, state}

      _item ->
        notify(state, {:receipt, ref, :failed})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:poll, ref}, %{items: items} = state) when not is_map_key(items, ref), do: {:noreply, state}

  def handle_info({:expire, ref}, state), do: {:noreply, update_in(state.items, &Map.delete(&1, ref))}

  def handle_info({:poll, ref}, state) do
    item = state.items[ref]
    result = safely(fn -> listener(state).receipt(item.id, 200) end)
    status = DeliveryReceipt.status(result)
    if item.status != status, do: notify(state, {:receipt, ref, status})
    item = %{item | status: status, delivered_at: item.delivered_at || delivered_at(status, result)}
    state = put_in(state.items[ref], item)
    {:noreply, observe(state, ref, item)}
  end

  def handle_info({:live_conversation_changed, snapshot}, state), do: {:noreply, replies(state, snapshot)}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    state = %{state | subscribers: Map.delete(state.subscribers, pid)}
    if map_size(state.subscribers) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(_event, state), do: {:noreply, state}

  defp enqueue(state, ref, text, key, kind) do
    result = safely(fn -> listener(state).send(state.target.identity, text, client_request_id: key, origin: :voice_assistant, delivery_policy: :checkpoint) end)
    Process.send_after(self(), {:expire, ref}, Keyword.get(state.opts, :timeout_ms, 300_000))
    item = %{id: nil, text: text, kind: kind, status: nil, delivered_at: nil, replied: false}

    case result do
      {:ok, id} ->
        send(self(), {:poll, ref})
        put_in(state.items[ref], %{item | id: id})

      {:error, reason} ->
        status = DeliveryReceipt.send_error(reason)
        notify(state, {:receipt, ref, status})
        put_in(state.items[ref], %{item | status: status})
    end
  end

  defp observe(state, ref, item) do
    if item.status == :accepted do
      Process.send_after(self(), {:poll, ref}, Keyword.get(state.opts, :poll_ms, 5_000))
    end

    if item.kind == :ask and not is_nil(item.delivered_at) and not item.replied and state.target.live_source do
      replies(state, state.live.snapshot(state.target.live_source))
    else
      state
    end
  end

  defp replies(state, %{messages: messages}) do
    Enum.reduce(state.items, state, fn {ref, item}, acc ->
      reply = if item.kind == :ask and not is_nil(item.delivered_at) and not item.replied, do: Enum.find(messages, &after_delivery?(&1, item.delivered_at))

      if reply do
        notify(acc, {:agent_reply, ref, reply.body})
        put_in(acc.items[ref].replied, true)
      else
        acc
      end
    end)
  end

  defp replies(state, _snapshot), do: state
  defp after_delivery?(%{role: "agent", occurred_at: %DateTime{} = at}, delivered), do: DateTime.compare(at, delivered) == :gt
  defp after_delivery?(_message, _delivered), do: false
  defp delivered_at(:delivered, {:ok, receipt}), do: receipt.observed_at
  defp delivered_at(_status, _result), do: nil
  defp notify(state, message), do: Enum.each(Map.keys(state.subscribers), &send(&1, message))
  defp listener(state), do: Keyword.get(state.opts, :listener, Aiur.Listener)

  defp safely(fun) do
    fun.()
  rescue
    _error -> {:error, {:outcome_unknown, %{}}}
  catch
    :exit, _reason -> {:error, {:outcome_unknown, %{}}}
  end
end
