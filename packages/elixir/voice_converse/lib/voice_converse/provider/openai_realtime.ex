defmodule VoiceConverse.Provider.OpenAIRealtime do
  @moduledoc "Daemon-held GA Realtime websocket adapter. No browser credentials or live test calls."
  use GenServer
  @behaviour VoiceConverse.Provider

  alias VoiceConverse.Events
  alias VoiceConverse.Provider.OpenAIRealtime.{PCM, Protocol, Transport}

  @impl true
  def descriptor do
    %{
      id: :openai_realtime,
      family: :speech_to_speech,
      label: "OpenAI Realtime",
      modes: [:voice],
      needs: [:openai],
      privacy: %{audio_stored_by_provider: true, deletable?: false},
      price_hint: "token-priced"
    }
  end

  @impl true
  def capabilities, do: %{events: Events.all(), text_only?: false}

  @impl true
  def open(%{owner: owner, credentials: {credentials, id}, llm: model, audio_in: :pcm_16000} = spec)
      when is_pid(owner) and is_binary(model) and byte_size(model) > 0 do
    case credentials.fetch(id, :probe) do
      {:ok, :present} -> GenServer.start(__MODULE__, spec)
      _ -> {:error, Events.Error.new(:unconfigured, "OpenAI Realtime is not configured.")}
    end
  rescue
    _ -> {:error, Events.Error.new(:provider_auth, "OpenAI Realtime authentication failed.")}
  end

  def open(_), do: {:error, Events.Error.new(:provider_error, "Invalid OpenAI Realtime session specification.")}

  @impl true
  def push_audio(ref, audio), do: GenServer.cast(ref, {:audio, audio})
  @impl true
  def send_context(ref, text), do: GenServer.cast(ref, {:context, text})
  @impl true
  def send_user_text(ref, text), do: GenServer.cast(ref, {:text, text})
  @impl true
  def tool_result(ref, id, result), do: GenServer.cast(ref, {:tool, id, result})
  @impl true
  def close(ref), do: GenServer.cast(ref, :close)

  @impl true
  def init(spec) do
    Process.flag(:sensitive, true)
    Process.monitor(spec.owner)

    state = %{
      owner: spec.owner,
      spec: spec,
      transport: Map.get(spec, :transport, Transport),
      conn: nil,
      ready?: false,
      timer: nil,
      queue: [],
      queue_bytes: 0,
      tail: <<>>,
      turn: nil,
      pending: MapSet.new(),
      tool_buffer: [],
      seen: MapSet.new(),
      responding?: false,
      continuation?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {credentials, id} = state.spec.credentials
    url = "wss://api.openai.com/v1/realtime?" <> URI.encode_query(%{model: state.spec.llm})

    with {:ok, key} when is_binary(key) and byte_size(key) > 0 <- credentials.fetch(id, :connect),
         {:ok, conn} <- state.transport.connect(url, [{"Authorization", "Bearer " <> key}]) do
      state = %{state | conn: conn, timer: Process.send_after(self(), :initialization_timeout, 5_000)}
      transmit(state, [Protocol.setup(state.spec)])
    else
      _ -> fail(state, :provider_unavailable)
    end
  rescue
    _ -> fail(state, :provider_unavailable)
  catch
    _, _ -> fail(state, :provider_unavailable)
  end

  @impl true
  def handle_cast(:close, state), do: {:stop, :normal, state}
  def handle_cast(message, %{ready?: false} = state), do: enqueue(state, message)

  def handle_cast({:audio, audio}, state) do
    case PCM.convert(audio, state.tail) do
      {:ok, "", tail} -> {:noreply, %{state | tail: tail}}
      {:ok, audio, tail} -> transmit(%{state | tail: tail}, [%{type: "input_audio_buffer.append", audio: audio}])
      {:error, _} -> fail(state, :provider_error)
    end
  end

  def handle_cast({:context, text}, state), do: transmit(state, [Protocol.message("system", text)])

  def handle_cast({:text, text}, state),
    do: transmit(state, [Protocol.message("user", text), %{type: "response.create"}])

  def handle_cast({:tool, id, result}, state) do
    if MapSet.member?(state.pending, id) do
      frame = %{
        type: "conversation.item.create",
        item: %{type: "function_call_output", call_id: id, output: Jason.encode!(result)}
      }

      state = %{state | pending: MapSet.delete(state.pending, id), continuation?: true}
      {state, continuation} = continuation(state)
      transmit(state, [frame | continuation])
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:openai_realtime_transport, :text, text}, state) do
    case Jason.decode(text) do
      {:ok, frame} when is_map(frame) -> frame(frame, state)
      _ -> fail(state, :provider_error)
    end
  end

  def handle_info({:openai_realtime_transport, :closed, code}, state) do
    emit(state, %Events.Closed{reason: if(state.ready?, do: {:provider_closed, code}, else: :provider_error)})
    {:stop, :normal, state}
  end

  def handle_info({:openai_realtime_transport, :closed}, state),
    do: handle_info({:openai_realtime_transport, :closed, 1000}, state)

  def handle_info({:openai_realtime_transport, :error, _}, state), do: fail(state, :provider_unavailable)
  def handle_info(:initialization_timeout, %{ready?: false} = state), do: fail(state, :provider_unavailable)
  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.conn, do: state.transport.close(state.conn)
    :ok
  end

  defp frame(%{"type" => "session.created", "session" => %{"id" => id}}, state) when is_binary(id) do
    emit(state, %Events.ProviderConversationId{id: id})
    {:noreply, state}
  end

  defp frame(%{"type" => "session.updated"}, %{ready?: false} = state) do
    Process.cancel_timer(state.timer)
    queue = Enum.reverse(state.queue)
    state = %{state | ready?: true, queue: [], queue_bytes: 0, timer: nil}

    case flush_queue(state, queue) do
      {:noreply, state} -> greet(state)
      stopped -> stopped
    end
  end

  defp frame(%{"type" => "input_audio_buffer.speech_started"}, %{turn: turn} = state) when is_binary(turn) do
    emit(state, %Events.Interruption{turn_id: turn})
    # No browser playback-offset feedback yet: discard the interrupted item from
    # model context conservatively, including any audio the operator did not hear.
    transmit(%{state | turn: nil}, [
      %{type: "conversation.item.truncate", item_id: turn, content_index: 0, audio_end_ms: 0}
    ])
  end

  defp frame(%{"type" => "response.created"}, state), do: {:noreply, %{state | responding?: true}}

  defp frame(%{"type" => "response.done", "response" => %{"status" => "failed"}}, state),
    do: fail(state, :provider_error)

  defp frame(%{"type" => "response.done", "response" => %{"status" => "completed"}}, state) do
    case completed_tools(state) do
      {:ok, state} ->
        {state, frames} = continuation(%{state | responding?: false, tool_buffer: []})
        transmit(state, frames)

      :invalid ->
        fail(state, :provider_error)
    end
  end

  defp frame(%{"type" => "response.done"}, state),
    do: {:noreply, %{state | responding?: false, tool_buffer: []}}

  defp frame(%{"type" => "response.function_call_arguments.done"} = frame, state) do
    # Arguments-done also fires for cancelled/incomplete responses, possibly with
    # partial JSON. Parse and execute only after a successful response.done.
    if length(state.tool_buffer) < 32 and MapSet.size(state.seen) < 512 do
      {:noreply, %{state | tool_buffer: [frame | state.tool_buffer]}}
    else
      fail(state, :provider_error)
    end
  end

  defp frame(frame, state) do
    case Protocol.decode(frame) do
      %Events.Error{code: code} ->
        fail(state, code)

      %Events.AgentAudio{turn_id: id} = event ->
        emit(state, event)
        {:noreply, %{state | turn: id}}

      :invalid ->
        fail(state, :provider_error)

      :ignore ->
        {:noreply, state}

      event ->
        emit(state, event)
        {:noreply, state}
    end
  end

  defp completed_tools(state) do
    tools = state.tool_buffer |> Enum.reverse() |> Enum.map(&Protocol.decode/1)

    if Enum.all?(tools, &match?(%Events.ToolCall{}, &1)) do
      {:ok, Enum.reduce(tools, state, &deliver_tool/2)}
    else
      :invalid
    end
  end

  defp deliver_tool(%Events.ToolCall{call_id: id} = event, state) do
    if MapSet.member?(state.seen, id) do
      state
    else
      emit(state, event)
      %{state | pending: MapSet.put(state.pending, id), seen: MapSet.put(state.seen, id)}
    end
  end

  defp continuation(%{responding?: false, continuation?: true} = state) do
    if MapSet.size(state.pending) == 0 do
      {%{state | continuation?: false, responding?: true}, [%{type: "response.create"}]}
    else
      {state, []}
    end
  end

  defp continuation(state), do: {state, []}

  defp greet(state) do
    if state.spec.first_message do
      transmit(state, [
        Protocol.message("system", "Begin by saying: " <> state.spec.first_message),
        %{type: "response.create"}
      ])
    else
      {:noreply, state}
    end
  end

  defp flush_queue(state, []), do: {:noreply, state}

  defp flush_queue(state, [message | rest]) do
    case handle_cast(message, state) do
      {:noreply, state} -> flush_queue(state, rest)
      stopped -> stopped
    end
  end

  defp enqueue(state, message) do
    bytes = state.queue_bytes + :erlang.external_size(message)

    if bytes > 426_668 do
      fail(state, :provider_unavailable)
    else
      {:noreply, %{state | queue: [message | state.queue], queue_bytes: bytes}}
    end
  end

  defp transmit(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case state.transport.send_text(state.conn, Jason.encode!(frame)) do
        {:ok, conn} -> {:cont, {:ok, %{state | conn: conn}}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, state} -> {:noreply, state}
      :error -> fail(state, :provider_unavailable)
    end
  rescue
    _ -> fail(state, :provider_unavailable)
  catch
    _, _ -> fail(state, :provider_unavailable)
  end

  defp fail(state, code) do
    emit(state, Events.Error.new(code, "OpenAI Realtime session failed."))
    emit(state, %Events.Closed{reason: code})
    {:stop, :normal, state}
  end

  defp emit(state, event), do: send(state.owner, {:voice_conversation, self(), event})
end
