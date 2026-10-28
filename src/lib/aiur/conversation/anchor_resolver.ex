defmodule Aiur.Conversation.AnchorResolver do
  @moduledoc "Live bus subscriber resolving durable conversation jump points; pending exacts are intentionally volatile."
  use GenServer
  alias Aiur.Conversation.{Anchors, History, Ingest, JumpPoints, Ref, ResolverState}
  alias Aiur.Events

  @patterns ["ticket.*.agent.#", "ticket.*.pr.#", "ticket.*.ci.#", "ticket.*.branch.push", "ticket.*.issue.commented", "executor.#"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec anchor_for_decision(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def anchor_for_decision(id, server \\ __MODULE__) do
    GenServer.call(server, {:decision, id})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    exchange = Keyword.get(opts, :exchange, Events.exchange_server())
    Enum.each(@patterns, &Events.subscribe(&1, exchange))
    {root, cursor, decisions} = ResolverState.load()
    journal_opts = Application.get_env(:aiur, :conversation_journal, [])
    timer = Keyword.get(opts, :send_after, &Process.send_after/3)
    monotonic = Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end)
    timer.(self(), :save_cursor, 5_000)

    {:ok,
     %{
       root: root,
       cursor: cursor,
       decisions: decisions,
       pubsub: Keyword.get(opts, :pubsub, Keyword.get(journal_opts, :pubsub, Aiur.PubSub)),
       send_after: timer,
       pending: %{},
       counts: %{},
       tokens: 20,
       refill_at: monotonic.(),
       monotonic: monotonic,
       queued: :queue.new(),
       drain_timer: nil
     }}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.counts, state}
  def handle_call({:decision, id}, _from, state), do: {:reply, decision_result(Map.fetch(state.decisions, id)), state}

  @impl true
  def handle_cast({:anchor_persisted, anchor}, state), do: {:noreply, %{state | decisions: ResolverState.remember(state.decisions, anchor)}}

  @impl true
  def handle_info({:event, event}, state), do: {:noreply, drain(%{state | queued: :queue.in(event, state.queued)})}
  def handle_info(:drain, state), do: {:noreply, drain(%{state | drain_timer: nil})}

  def handle_info({:entries_appended, id, entries}, state) do
    state =
      Enum.reduce(Map.get(state.pending, id, %{}), state, fn {key, {ref, event, timer}}, acc ->
        case Anchors.exact(event, entries) do
          {:ok, anchor} ->
            Ingest.anchor(ref, anchor)
            Process.cancel_timer(timer)
            remove_pending(acc, id, key)

          :none ->
            acc
        end
      end)

    {:noreply, state}
  end

  def handle_info({:exact_expired, id, key}, state) do
    if get_in(state.pending, [id, key]),
      do: {:noreply, state |> remove_pending(id, key) |> count(:exact_expired)},
      else: {:noreply, state}
  end

  def handle_info(:save_cursor, state) do
    result = ResolverState.save(state.root, state.cursor)
    state.send_after.(self(), :save_cursor, 5_000)
    {:noreply, if(result == :ok, do: state, else: count(state, :cursor_failed))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drain(state) do
    now = state.monotonic.()
    # Initial burst 20, replenishing one window read every 50ms.
    refill = div(now - state.refill_at, 50)
    consume(%{state | tokens: min(20, state.tokens + refill), refill_at: state.refill_at + refill * 50})
  end

  defp consume(%{tokens: 0} = state), do: schedule_drain(state)

  defp consume(state) do
    case :queue.out(state.queued) do
      {:empty, _} -> state
      {{:value, event}, rest} -> resolve(event, %{state | queued: rest, tokens: state.tokens - 1}) |> consume()
    end
  end

  defp schedule_drain(%{drain_timer: nil} = state) do
    if :queue.is_empty(state.queued), do: state, else: %{state | drain_timer: state.send_after.(self(), :drain, 50)}
  end

  defp schedule_drain(state), do: state

  defp resolve(raw, state) do
    topic = field(raw, :topic)
    observation = field(raw, :ticket_observation) || %{}
    state = remember_cursor(state, field(observation, :event_id))

    with kind when not is_nil(kind) <- JumpPoints.kind_for(topic),
         {:ok, ref} <- subject(topic, observation),
         event_id when is_integer(event_id) and event_id > 0 <- field(observation, :event_id) do
      event = event(raw, observation, ref, kind, event_id)
      # Subscribe before reading: racing appends are in the snapshot or mailbox.
      state = subscribe(state, event.conversation_id)
      {entries, sessions} = window(ref)
      resolve_anchor(state, ref, event, entries, sessions)
    else
      nil -> count(state, :ignored_kind)
      _ -> count(state, :unjoinable)
    end
  end

  defp resolve_anchor(state, ref, event, entries, sessions) do
    case Anchors.exact(event, entries) do
      {:ok, anchor} ->
        Ingest.anchor(ref, anchor)
        unsubscribe_if_empty(state, event.conversation_id)

      :none ->
        {:ok, anchor} = Anchors.position(event, entries, sessions)
        Ingest.anchor(ref, anchor)
        pending(state, ref, event)
    end
  end

  defp window(ref) do
    entries =
      case History.list_entries(ref, tail: true, limit: 200, principal: :internal) do
        {:ok, page} -> page.entries
        _ -> []
      end

    sessions =
      case History.list_sessions(ref) do
        {:ok, sessions} -> sessions
        _ -> []
      end

    {entries, sessions}
  end

  defp pending(state, ref, event) do
    tool_id = if event.kind == "command_requested", do: event.decision_tool_call_id, else: event.source_tool_call_id
    id = event.conversation_id
    key = {event.event_id, event.kind}

    if is_binary(tool_id) and tool_id != "" and is_nil(get_in(state.pending, [id, key])) do
      timer = state.send_after.(self(), {:exact_expired, id, key}, 120_000)
      %{state | pending: Map.update(state.pending, id, %{key => {ref, event, timer}}, &Map.put(&1, key, {ref, event, timer}))}
    else
      unsubscribe_if_empty(state, id)
    end
  end

  defp subscribe(state, id) do
    unless Map.has_key?(state.pending, id), do: Phoenix.PubSub.subscribe(state.pubsub, "conversation:" <> id)
    state
  end

  defp remove_pending(state, id, key) do
    pending = Map.update!(state.pending, id, &Map.delete(&1, key))
    unsubscribe_if_empty(%{state | pending: pending}, id)
  end

  defp unsubscribe_if_empty(state, id) do
    if map_size(Map.get(state.pending, id, %{})) == 0 do
      Phoenix.PubSub.unsubscribe(state.pubsub, "conversation:" <> id)
      %{state | pending: Map.delete(state.pending, id)}
    else
      state
    end
  end

  defp subject("executor." <> _, _observation) do
    ref = Ref.executor()

    case History.list_sessions(ref) do
      {:ok, _} -> {:ok, ref}
      _ -> {:error, :not_found}
    end
  end

  defp subject(_topic, observation) do
    if field(observation, :status) == :joinable,
      do: Ref.worker(field(observation, :tracker_identity)),
      else: {:error, :unjoinable}
  end

  defp event(raw, observation, ref, kind, id) do
    %{
      event_id: id,
      topic: field(raw, :topic),
      kind: kind,
      conversation_id: Ref.conversation_id(ref),
      observed_at: field(observation, :observed_at),
      occurred_at: field(observation, :occurred_at),
      source_tool_call_id: field(field(observation, :provenance) || %{}, :source_event_id),
      decision_tool_call_id: field(field(raw, :source) || %{}, :event_id),
      subject_ref: %{"head_sha" => field(raw, :sha), "pr_number" => field(field(raw, :pr) || %{}, :number), "decision_id" => field(raw, :decision_id)}
    }
  end

  defp remember_cursor(state, id) when is_integer(id) and id > 0,
    do: %{state | cursor: Map.update(state.cursor, "last_event_id", id, &max(&1, id))}

  defp remember_cursor(state, _id), do: state
  defp count(state, key), do: %{state | counts: Map.update(state.counts, key, 1, &(&1 + 1))}
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
  defp decision_result({:ok, anchor}), do: {:ok, anchor}
  defp decision_result(:error), do: {:error, :not_found}
end
