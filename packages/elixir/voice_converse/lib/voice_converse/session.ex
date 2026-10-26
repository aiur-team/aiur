defmodule VoiceConverse.Session do
  use GenServer, restart: :temporary

  alias VoiceConverse.{
    ClientErrors,
    Config,
    Events,
    ProviderCleanup,
    SessionLimits,
    SessionRegistry,
    TranscriptStore
  }

  @transport_grace_ms 10_000
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

    case start_state(config, target, id, opts) do
      {:ok, state} ->
        {:ok, state, {:continue, :open_provider}}

      {:error, code} ->
        {:stop, {:session_start_failed, code}}
    end
  end

  @impl true
  def handle_continue(:open_provider, state) do
    case open_provider(state) do
      {:ok, state} ->
        broadcast_state(state, :connecting)
        {:noreply, schedule_limits(state)}

      {:error, code, state} ->
        {:stop, {:session_start_failed, code}, close_after_start_failure(state, code)}
    end
  end

  @impl true
  def handle_cast({:audio, audio_b64}, %{provider_ref: ref, provider: provider} = state) when is_binary(audio_b64) do
    :ok = provider.push_audio(ref, audio_b64)
    {:noreply, state}
  end

  def handle_cast({:audio, _audio_b64}, state), do: {:noreply, state}
  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    state = add_subscriber(state, subscriber)
    send(subscriber, {:voice_conversation_state, state.id, state.state})
    {:reply, :ok, state}
  end

  def handle_call({:end, reason}, _from, state) do
    case finish(state, valid_end_reason(reason)) do
      {:ok, state} -> {:stop, :normal, :ok, state}
      {:error, state} -> {:stop, :normal, {:error, :unknown}, state}
    end
  end

  @impl true
  def handle_info(:provider_ready, state), do: {:noreply, transition(state, :listening)}

  def handle_info({:idle_timeout, token}, %{idle_token: token} = state), do: stop_on_timeout(state, :idle_timeout)

  def handle_info({:idle_timeout, _token}, state), do: {:noreply, state}
  def handle_info(:max_duration, state), do: stop_on_timeout(state, :max_duration)

  def handle_info({:transport_grace, token}, %{transport_token: token, subscribers: subscribers} = state)
      when map_size(subscribers) == 0 do
    case finish(state, :transport_lost) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({:transport_grace, _token}, state), do: {:noreply, state}

  def handle_info({:voice_conversation, ref, event}, %{provider_ref: ref} = state) do
    handle_provider_event(event, state)
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, ^monitor} -> {:noreply, remove_subscriber(state, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}
  @impl true
  def terminate(reason, state) when reason not in [:normal, :shutdown] do
    _ = finish(state, :transport_lost)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_state(config, target, id, opts) do
    with :ok <- Config.check_session_start(config),
         :ok <- target_alive?(config, target),
         {:ok, provider, provider_opts} <- provider(config, opts),
         :ok <- preflight(provider, provider_spec(config, target, provider, provider_opts)),
         :ok <- SessionLimits.under_daily_cap?(config),
         {:ok, store} <- open_transcript(config, target, id, provider, opts) do
      state = %{
        id: id,
        config: config,
        target: target,
        provider: provider,
        provider_opts: provider_opts,
        provider_ref: nil,
        provider_id: nil,
        store: store,
        state: :connecting,
        subscribers: %{},
        reconnects: 0,
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        schedule_after: Keyword.get(opts, :schedule_after, &Process.send_after(self(), &2, &1)),
        transport_token: nil,
        idle_token: nil,
        started_at: Keyword.get(opts, :clock, &DateTime.utc_now/0).()
      }

      state = if client = Keyword.get(opts, :client), do: add_subscriber(state, client), else: state
      {:ok, state}
    else
      {:error, %{field: field}} -> {:error, field}
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :unknown}
    end
  end

  defp target_alive?(%Config{briefing_source: source}, target) do
    case source.alive?(target) do
      false -> {:error, :target_gone}
      _ -> :ok
    end
  rescue
    _error -> {:error, :target_gone}
  end

  defp provider(config, opts) do
    case Keyword.get(opts, :provider, config.provider) do
      {module, provider_opts} when is_atom(module) and is_list(provider_opts) -> {:ok, module, provider_opts}
      module when is_atom(module) -> {:ok, module, []}
      _ -> {:error, :unconfigured}
    end
  end

  defp preflight(provider, spec) do
    if function_exported?(provider, :preflight, 1) do
      case provider.preflight(spec) do
        :ok -> :ok
        {:error, %Events.Error{}} -> {:error, :privacy_preflight_failed}
        _ -> {:error, :privacy_preflight_failed}
      end
    else
      :ok
    end
  end

  defp open_transcript(config, target, id, provider, opts) do
    source = config.briefing_source
    descriptor = source.describe_target(target)
    provider_id = provider.descriptor().id

    TranscriptStore.start(config, id, %{
      target: descriptor,
      role_id: Keyword.get(opts, :role_id),
      provider: to_string(provider_id),
      model: config.llm
    })
  rescue
    _error -> {:error, :unknown}
  end

  defp open_provider(state) do
    spec = provider_spec(state.config, state.target, state.provider, state.provider_opts, self())

    case state.provider.open(spec) do
      {:ok, ref} -> {:ok, %{state | provider_ref: ref}}
      {:error, %Events.Error{code: code}} -> {:error, provider_code(code), state}
      _ -> {:error, :provider_error, state}
    end
  rescue
    _error -> {:error, :provider_error, state}
  end

  defp provider_spec(config, target, provider, provider_opts, owner \\ nil) do
    provider_id = provider.descriptor().id

    %{
      owner: owner || self(),
      credentials: {config.credentials, provider_id},
      system_prompt: "",
      first_message: nil,
      context: "",
      tools: [],
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      llm: config.llm,
      target: target,
      fake: provider_opts
    }
  end

  defp schedule_limits(state) do
    duration_ms = state.config.limits.max_session_seconds * 1_000
    state.schedule_after.(duration_ms, :max_duration)
    reset_idle_timer(state)
  end

  defp stop_on_timeout(state, reason) do
    case finish(state, reason) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:stop, :normal, state}
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
        {:noreply, %{state | provider_id: provider_id}}

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
    {:noreply, state}
  end

  defp handle_provider_event(%Events.AgentText{final?: true, turn_id: turn_id, text: text} = event, state) do
    record = %{type: "assistant_turn", turn_id: to_string(turn_id), text: redact(state, text), at: now(state)}
    persist_and_broadcast(state, record, event, :listening)
  end

  defp handle_provider_event(%Events.AgentText{} = event, state) do
    broadcast(state, event)
    {:noreply, transition(state, :speaking)}
  end

  defp handle_provider_event(%Events.AgentAudio{} = event, state) do
    broadcast(state, event)
    {:noreply, transition(state, :speaking)}
  end

  defp handle_provider_event(%Events.Interruption{} = event, state) do
    broadcast(state, event)
    {:noreply, transition(state, :listening)}
  end

  defp handle_provider_event(%Events.ToolCall{} = event, state) do
    record = %{type: "tool_call", call_id: event.call_id, name: event.name, params: event.params, at: now(state)}
    persist_and_broadcast(state, record, event, state.state)
  end

  defp handle_provider_event(%Events.Error{code: code} = event, state) do
    code = provider_code(code)
    broadcast(state, {:error, code, event.message})

    case finish(state, if(code == :provider_quota, do: :provider_quota, else: :provider_error)) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  defp handle_provider_event(%Events.Closed{}, %{reconnects: 0} = state) do
    state = transition(state, :reconnecting)

    case open_provider(%{state | reconnects: 1, provider_ref: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, _code, state} -> stop_provider_error(state)
    end
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

  defp finish(state, reason) do
    state.provider_ref && state.provider.close(state.provider_ref)
    duration_s = max(DateTime.diff(state.clock.(), state.started_at), 0)

    with {:ok, state} <-
           persist(state, %{type: "session_ended", reason: to_string(reason), at: now(state), duration_s: duration_s}),
         {:ok, state} <- enqueue_cleanup(state) do
      broadcast(state, {:ended, reason})
      broadcast_state(state, :ended)
      TranscriptStore.close(state.store)
      {:ok, %{state | state: :ended}}
    else
      {:error, state} -> {:error, state}
    end
  end

  defp enqueue_cleanup(%{provider_id: nil} = state), do: {:ok, state}

  defp enqueue_cleanup(state) do
    cleanup = Module.concat(state.config.name, ProviderCleanup)

    with :ok <- ProviderCleanup.enqueue(cleanup, state.provider_id, state.id),
         {:ok, state} <- persist(state, %{type: "cleanup_enqueued", provider_id: state.provider_id, at: now(state)}) do
      {:ok, state}
    else
      _ -> {:error, state}
    end
  end

  defp close_after_start_failure(%{store: store} = state, code) do
    _ = TranscriptStore.append(store, %{type: "session_ended", reason: to_string(code), at: now(state)})
    _ = TranscriptStore.close(store)
    state
  end

  defp close_after_start_failure(state, _code), do: state

  defp stop_provider_error(state) do
    case finish(transition(state, :error), :provider_error) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  defp stop_unknown(state) do
    case finish(state, :unknown) do
      {:ok, state} -> {:stop, :normal, state}
      {:error, state} -> {:stop, :normal, state}
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
    %{state | subscribers: Map.put(state.subscribers, subscriber, Process.monitor(subscriber)), transport_token: nil}
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
          state.schedule_after.(@transport_grace_ms, {:transport_grace, token})
          %{state | transport_token: token}
        else
          state
        end
    end
  end

  defp reset_idle_timer(state) do
    token = make_ref()
    timeout = state.config.limits.idle_timeout_seconds * 1_000
    state.schedule_after.(timeout, {:idle_timeout, token})
    %{state | idle_token: token}
  end

  defp broadcast(state, event),
    do: Enum.each(Map.keys(state.subscribers), &send(&1, {:voice_conversation, state.id, event}))

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
