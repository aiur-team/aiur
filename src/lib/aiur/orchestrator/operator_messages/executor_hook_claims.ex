defmodule Aiur.Orchestrator.OperatorMessages.ExecutorHookClaims do
  @moduledoc "Serialized Executor hook batches; rendering and persistence precede the returned envelope."

  alias Aiur.{AgentQueueStore, Orchestrator}
  alias Aiur.AgentQueueStore.Items
  alias Aiur.Conversation.Ref
  alias Aiur.Executor.Session
  alias Aiur.Listener.{HookEnvelope, ModeStore, Scheduler}
  alias Aiur.Orchestrator.OperatorMessages.PendingStore

  @spec claim_executor_hook_batch(String.t(), atom(), keyword()) :: {:ok, String.t()} | :none
  def claim_executor_hook_batch(binding_id, boundary, limits) do
    server = Keyword.get(limits, :server, Orchestrator)
    remaining = limits[:deadline] - System.monotonic_time(:millisecond)

    if remaining > 0 do
      GenServer.call(server, {:claim_executor_hook_batch, binding_id, boundary, limits}, remaining)
    else
      :none
    end
  catch
    :exit, _ ->
      restore(server_for(limits), limits[:attempt])
      :none
  end

  @spec restore(GenServer.server(), String.t()) :: :ok
  def restore(server, attempt), do: GenServer.cast(server, {:restore_executor_hook_batch, attempt})

  @spec handle_call(Aiur.Orchestrator.State.t(), String.t(), atom(), keyword()) :: tuple()
  def handle_call(state, binding_id, boundary, opts) do
    with true <- before_deadline?(opts),
         {:ok, binding} <- current(opts),
         true <- matches?(binding, binding_id, opts),
         # shortcut: use requested mode until the Executor effective view exists.
         mode <- ModeStore.get(Ref.canonical(Ref.executor())).requested,
         true <- Scheduler.hook_delivers?(binding.harness, mode, boundary),
         items <- pending(state.queue_store),
         {:ok, output, count} <- render(binding.harness, boundary, items, opts),
         true <- before_deadline?(opts) do
      store = Enum.reduce(Enum.take(items, count), state.queue_store, &mark(&2, &1, binding, boundary, opts[:attempt]))
      commit(state, store, output, opts)
    else
      _ -> {:reply, :none, state}
    end
  rescue
    _ -> {:reply, :none, state}
  catch
    :exit, _ -> {:reply, :none, state}
  end

  @spec restore_call(Aiur.Orchestrator.State.t(), String.t()) :: tuple()
  def restore_call(state, attempt) do
    store =
      state.queue_store.items
      |> Map.values()
      |> Enum.filter(&(&1.target_issue_identifier == "executor" and &1.status == :delivered and &1.delivery[:delivery_attempt_id] == attempt))
      |> Enum.reduce(state.queue_store, fn item, store ->
        {store, restored} = AgentQueueStore.restore_pending(store, item.id)
        Items.put_item(store, %{restored | delivery: Map.drop(restored.delivery, [:delivery_attempt_id, :delivered_via, :hook_event, :binding_id, :generation])})
      end)

    # Keep the in-memory retry even if storage is unavailable; save reports the durable failure.
    PendingStore.save(store)
    {:noreply, %{state | queue_store: store}}
  end

  defp current(opts), do: GenServer.call(Session, :current, max(1, opts[:deadline] - System.monotonic_time(:millisecond)))

  defp matches?(binding, id, opts) do
    binding.binding_id == id and binding.generation == opts[:generation] and binding.state == "attached" and binding.live? and
      binding.provider_session_id == opts[:session_id] and binding.harness == opts[:harness]
  end

  defp pending(store) do
    store
    |> AgentQueueStore.list_pending("executor")
    |> Enum.filter(&(&1.category == :operator_message and &1.delivery[:consume_at] != :pull))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.take(50)
  end

  defp render(harness, boundary, items, opts) do
    entries = Enum.map(items, &%{body: &1.body.text, sender_label: &1.actor || "operator", sender_kind: "operator", ts: DateTime.to_iso8601(&1.inserted_at), delivery_id: &1.id})
    Keyword.get(opts, :render, &HookEnvelope.render/3).(harness, boundary, entries)
  end

  defp mark(store, item, binding, boundary, attempt) do
    now = DateTime.utc_now()
    delivery = Map.merge(item.delivery, %{delivery_attempt_id: attempt, delivered_via: :hook, hook_event: boundary, binding_id: binding.binding_id, generation: binding.generation})
    item = %{item | status: :delivered, delivered_at: now, provider_delivered_at: now, delivery_attempts: item.delivery_attempts + 1, delivery: delivery}
    store |> Items.put_item(item) |> Items.remove_pending_id("executor", item.id)
  end

  defp commit(state, store, output, opts) do
    case persist(store, opts) do
      :ok ->
        if before_deadline?(opts) do
          {:reply, {:ok, output}, %{state | queue_store: store}}
        else
          persist(state.queue_store, opts)
          {:reply, :none, state}
        end

      {:error, _} ->
        {:reply, :none, state}
    end
  end

  defp persist(store, opts), do: Keyword.get(opts, :persist, &PendingStore.save/1).(store)
  defp before_deadline?(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).() < opts[:deadline]
  defp server_for(opts), do: Keyword.get(opts, :server, Orchestrator)
end
