defmodule VoiceConverse.Session do
  use GenServer, restart: :temporary

  alias VoiceConverse.{
    ClientErrors,
    Events,
    ProviderCleanup,
    Session.Runtime,
    Session.Start,
    SessionLimits,
    SessionRegistry,
    Tools,
    TranscriptStore
  }

  @transport_grace_ms 10_000
  @max_queued_audio 8
  def start_link(opts) do
    id = Keyword.fetch!(opts, :conversation_id)
    instance = Keyword.fetch!(opts, :instance)
    GenServer.start_link(__MODULE__, opts, name: SessionRegistry.via(instance, id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :conversation_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def push_audio(session, audio_b64), do: GenServer.cast(session, {:audio, audio_b64})
  def end_session(session, reason), do: GenServer.call(session, {:end, reason})
  def subscribe(session, subscriber), do: GenServer.call(session, {:subscribe, subscriber})
  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    target = Keyword.fetch!(opts, :target)
    id = Keyword.fetch!(opts, :conversation_id)

    case Start.state(config, target, id, opts) do
      {:ok, state} ->
        state = if client = Keyword.get(opts, :client), do: add_subscriber(state, client), else: state
        {:ok, state, {:continue, :open_provider}}

      {:error, code} ->
        {:stop, {:session_start_failed, code}}
    end
  end

  @impl true
  def handle_continue(:open_provider, state) do
    {:noreply, open_provider_async(state, :initial)}
  end

  @impl true
  def handle_cast({:audio, audio_b64}, state) when is_binary(audio_b64) do
    {:noreply, Runtime.enqueue_audio(self(), state, audio_b64, @max_queued_audio)}
  end

  def handle_cast({:audio, _audio_b64}, state), do: {:noreply, state}
  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    state = add_subscriber(state, subscriber)
    send(subscriber, {:voice_conversation_state, state.id, state.state})
    {:reply, :ok, state}
  end

  def handle_call(:await_started, _from, %{start_status: :started} = state), do: {:reply, :ok, state}
  def handle_call(:await_started, from, state), do: {:noreply, update_in(state.start_waiters, &[from | &1])}

  def handle_call({:end, reason}, _from, state) do
    case begin_finish(state, valid_end_reason(reason)) do
      {:done, state} -> {:stop, :normal, :ok, state}
      {:pending, state} -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:provider_ready, state), do: {:noreply, transition(state, :listening)}

  def handle_info({:provider_opened, phase, result}, state), do: handle_provider_opened(phase, result, state)

  def handle_info({:provider_closed, {:finish, reason}}, state) do
    {:stop, :normal, finish_after_close(state, reason)}
  end

  def handle_info({:provider_closed, :reconnect}, state), do: {:noreply, open_provider_async(state, :reconnect)}

  def handle_info({:audio_pushed, ref, _result}, %{provider_ref: ref} = state),
    do: {:noreply, state |> Map.put(:audio_task?, false) |> Runtime.start_next_audio(self())}

  def handle_info({:audio_pushed, _ref, _result}, state), do: {:noreply, state}

  def handle_info({:idle_timeout, token}, %{idle_token: token} = state), do: stop_on_timeout(state, :idle_timeout)

  def handle_info({:idle_timeout, _token}, state), do: {:noreply, state}
  def handle_info(:max_duration, state), do: stop_on_timeout(state, :max_duration)

  def handle_info({:transport_grace, token}, %{transport_token: token, subscribers: subscribers} = state)
      when map_size(subscribers) == 0 do
    case begin_finish(state, :transport_lost) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  def handle_info({:transport_grace, _token}, state), do: {:noreply, state}

  def handle_info({:voice_conversation, ref, event}, %{provider_ref: ref} = state) do
    handle_provider_event(event, state)
  end

  def handle_info({:end_after_tool_result, call_id}, %{end_tool_call_id: call_id} = state) do
    case begin_finish(state, :user_end) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  def handle_info({:end_after_tool_result, _call_id}, state), do: {:noreply, state}

  def handle_info({:voice_conversation, ref, event}, %{provider_ref: nil, opening: opening} = state)
      when not is_nil(opening) do
    {:noreply, update_in(state.deferred_events, &[{ref, event} | &1])}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, ^monitor} -> {:noreply, remove_subscriber(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}
  @impl true
  def terminate(reason, %{finished?: false} = state) when reason not in [:normal, :shutdown] do
    state = close_current_provider(state)
    _ = finish_after_close(state, :transport_lost)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_provider_async(state, phase) do
    Runtime.open(self(), state, phase)
    %{state | opening: phase}
  end

  defp handle_provider_opened(phase, {:ok, ref}, %{opening: phase} = state) do
    state = %{state | provider_ref: ref, opening: nil}

    state =
      if phase == :initial, do: state |> schedule_limits() |> announce_connecting() |> complete_start(:ok), else: state

    Enum.each(Enum.reverse(state.deferred_events), fn
      {^ref, event} -> send(self(), {:voice_conversation, ref, event})
      _ -> :ok
    end)

    {:noreply, %{state | deferred_events: []}}
  end

  defp handle_provider_opened(:initial, {:error, code}, state) do
    state = state |> complete_start({:error, code}) |> close_after_start_failure(code)
    {:stop, {:session_start_failed, code}, state}
  end

  defp handle_provider_opened(:initial, _result, state) do
    state = state |> complete_start({:error, :provider_error}) |> close_after_start_failure(:provider_error)
    {:stop, {:session_start_failed, :provider_error}, state}
  end

  defp handle_provider_opened(:reconnect, _result, state), do: stop_provider_error(state)

  defp schedule_limits(state) do
    duration_ms = state.config.limits.max_session_seconds * 1_000
    max_timer = state.schedule_after.(duration_ms, :max_duration)
    state |> Map.put(:max_timer, max_timer) |> reset_idle_timer()
  end

  defp announce_connecting(state), do: tap(state, &broadcast_state(&1, :connecting))

  defp complete_start(state, result) do
    Enum.each(state.start_waiters, &GenServer.reply(&1, result))
    %{state | start_status: if(result == :ok, do: :started, else: result), start_waiters: []}
  end

  defp stop_on_timeout(state, reason) do
    case begin_finish(state, reason) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  defp handle_provider_event(%Events.ProviderConversationId{id: provider_id} = event, state) do
    case persist(state, %{
           type: "provider_conversation",
           provider: to_string(state.provider.descriptor().id),
           id: provider_id,
           at: now(state)
         }) do
      {:ok, state} ->
        broadcast(state, event)
        send(self(), :provider_ready)
        {:noreply, update_in(state.provider_ids, &MapSet.put(&1, provider_id))}

      {:error, state} ->
        stop_unknown(state)
    end
  end

  defp handle_provider_event(%Events.UserTranscript{final?: true, text: text} = event, state) do
    persist_and_broadcast(
      state,
      %{type: "user_turn", turn_id: "user", text: redact(state, text), at: now(state)},
      event,
      :thinking
    )
  end

  defp handle_provider_event(%Events.UserTranscript{} = event, state) do
    broadcast(state, event)
    {:noreply, reset_idle_timer(state)}
  end

  defp handle_provider_event(%Events.AgentText{final?: true, turn_id: turn_id, text: text} = event, state) do
    record = %{type: "assistant_turn", turn_id: to_string(turn_id), text: redact(state, text), at: now(state)}
    persist_and_broadcast(state, record, event, :listening)
  end

  defp handle_provider_event(%Events.AgentText{} = event, state) do
    broadcast(state, event)
    {:noreply, state |> reset_idle_timer() |> transition(:speaking)}
  end

  defp handle_provider_event(%Events.AgentAudio{} = event, state) do
    broadcast(state, event)
    {:noreply, state |> reset_idle_timer() |> transition(:speaking)}
  end

  defp handle_provider_event(%Events.Interruption{} = event, state) do
    broadcast(state, event)
    {:noreply, state |> reset_idle_timer() |> transition(:listening)}
  end

  defp handle_provider_event(%Events.ToolCall{} = event, state) do
    record = %{type: "tool_call", call_id: event.call_id, name: event.name, params: event.params, at: now(state)}

    case persist(state, record) do
      {:ok, state} ->
        broadcast(state, event)
        result = Tools.handle(state, event)

        result_record = %{
          type: "tool_result",
          call_id: event.call_id,
          name: event.name,
          summary: result.text,
          is_error: result.is_error,
          at: now(state)
        }

        case persist(state, result_record) do
          {:ok, state} ->
            :ok = state.provider.tool_result(state.provider_ref, event.call_id, result)
            state = if result.end?, do: %{state | end_tool_call_id: event.call_id}, else: state
            if result.end?, do: send(self(), {:end_after_tool_result, event.call_id})
            {:noreply, state}

          {:error, state} ->
            stop_unknown(state)
        end

      {:error, state} ->
        stop_unknown(state)
    end
  end

  defp handle_provider_event(%Events.Error{code: code} = event, state) do
    code = provider_code(code)
    broadcast(state, {:error, code, event.message})

    case begin_finish(state, if(code == :provider_quota, do: :provider_quota, else: :provider_error)) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  defp handle_provider_event(%Events.Closed{}, %{reconnects: 0} = state) do
    state = transition(state, :reconnecting)
    {:noreply, close_provider(%{state | reconnects: 1}, :reconnect)}
  end

  defp handle_provider_event(%Events.Closed{}, state), do: stop_provider_error(state)

  defp persist_and_broadcast(state, record, event, next_state, reset_idle? \\ true) do
    case persist(state, record) do
      {:ok, state} ->
        broadcast(state, event)
        state = if reset_idle?, do: reset_idle_timer(state), else: state

        case SessionLimits.under_daily_cap?(state.config,
               now: state.clock.(),
               open_sessions: fn -> [%{started_at: state.started_at}] end
             ) do
          :ok -> {:noreply, transition(state, next_state)}
          {:error, :cost_cap} -> stop_on_timeout(state, :cost_cap)
          {:error, _code} -> stop_unknown(state)
        end

      {:error, state} ->
        stop_unknown(state)
    end
  end

  defp persist(state, record) do
    case TranscriptStore.append(state.store, record) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:error, state}
    end
  end

  defp begin_finish(%{finished?: true} = state, _reason), do: {:done, state}
  defp begin_finish(%{finishing?: true} = state, _reason), do: {:pending, state}

  defp begin_finish(%{provider_ref: nil} = state, reason), do: {:done, finish_after_close(state, reason)}

  defp begin_finish(state, reason), do: {:pending, close_provider(%{state | finishing?: true}, {:finish, reason})}

  defp finish_after_close(%{finished?: true} = state, _reason), do: state

  defp finish_after_close(state, reason) do
    Runtime.cancel_timer(state.idle_timer)
    Runtime.cancel_timer(state.max_timer)
    Runtime.cancel_timer(state.transport_timer)
    duration_s = max(DateTime.diff(state.clock.(), state.started_at), 0)

    with {:ok, state} <-
           persist(state, %{type: "session_ended", reason: to_string(reason), at: now(state), duration_s: duration_s}),
         {:ok, state} <- enqueue_cleanup(state) do
      broadcast(state, {:ended, reason})
      broadcast_state(state, :ended)
      TranscriptStore.close(state.store)
      %{state | state: :ended, finished?: true, finishing?: false, provider_ref: nil}
    else
      {:error, state} -> %{state | finished?: true, finishing?: false, provider_ref: nil}
    end
  end

  defp enqueue_cleanup(state) do
    cleanup = Module.concat(state.config.name, ProviderCleanup)

    Enum.reduce_while(state.provider_ids, {:ok, state}, fn provider_id, {:ok, state} ->
      with :ok <- ProviderCleanup.enqueue(cleanup, provider_id, state.id),
           {:ok, state} <- persist(state, %{type: "cleanup_enqueued", provider_id: provider_id, at: now(state)}) do
        {:cont, {:ok, state}}
      else
        _ -> {:halt, {:error, state}}
      end
    end)
  end

  defp close_after_start_failure(%{store: store} = state, code) do
    _ = TranscriptStore.append(store, %{type: "session_ended", reason: to_string(code), at: now(state)})
    _ = TranscriptStore.close(store)
    %{state | finished?: true}
  end

  defp close_after_start_failure(state, _code), do: state

  defp stop_provider_error(state) do
    case begin_finish(transition(state, :error), :provider_error) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  defp stop_unknown(state) do
    case begin_finish(state, :unknown) do
      {:done, state} -> {:stop, :normal, state}
      {:pending, state} -> {:noreply, state}
    end
  end

  defp transition(%{state: state} = session, state), do: session

  defp transition(session, state) do
    broadcast(session, {:state, state})
    broadcast_state(session, state)
    %{session | state: state}
  end

  defp add_subscriber(state, subscriber) do
    state = remove_subscriber(state, subscriber)
    Runtime.cancel_timer(state.transport_timer)

    %{
      state
      | subscribers: Map.put(state.subscribers, subscriber, Process.monitor(subscriber)),
        transport_token: nil,
        transport_timer: nil
    }
  end

  defp remove_subscriber(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | subscribers: subscribers}

        if map_size(subscribers) == 0 do
          token = make_ref()
          timer = state.schedule_after.(@transport_grace_ms, {:transport_grace, token})
          %{state | transport_token: token, transport_timer: timer}
        else
          state
        end
    end
  end

  defp reset_idle_timer(state) do
    Runtime.cancel_timer(state.idle_timer)
    token = make_ref()
    timeout = state.config.limits.idle_timeout_seconds * 1_000
    timer = state.schedule_after.(timeout, {:idle_timeout, token})
    %{state | idle_token: token, idle_timer: timer}
  end

  defp close_provider(state, action) do
    if ref = state.provider_ref, do: Runtime.close(self(), state.provider, ref, action)
    %{state | provider_ref: nil, audio_queue: :queue.new(), audio_task?: false}
  end

  defp close_current_provider(%{provider_ref: nil} = state), do: state

  defp close_current_provider(state) do
    _ = Runtime.close_current(state.provider, state.provider_ref)
    %{state | provider_ref: nil}
  end

  defp broadcast(state, event), do: state.event_broadcast.(state.subscribers, state.id, event)

  defp broadcast_state(state, name),
    do: Enum.each(Map.keys(state.subscribers), &send(&1, {:voice_conversation_state, state.id, name}))

  defp redact(state, text), do: state.config.redactor.(text)
  defp now(state), do: DateTime.to_iso8601(state.clock.())
  defp provider_code(:provider_quota), do: :provider_quota
  defp provider_code(code) when code in [:provider_auth, :provider_unavailable, :privacy_preflight_failed], do: code
  defp provider_code(_), do: :provider_error

  defp valid_end_reason(reason) do
    if Enum.any?(ClientErrors.table(), &(&1.code == reason and :end_reason in &1.kinds)), do: reason, else: :unknown
  end
end
