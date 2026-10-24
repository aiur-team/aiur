defmodule VoiceConverse.Provider.ElevenLabsAgents do
  @moduledoc """
  Connection-only ElevenLabs Agents adapter.

  The provider process owns the websocket. Credentials and the one-time signed
  URL are used while connecting and are never retained in its state.
  """

  use GenServer

  require Logger

  alias VoiceConverse.Events
  alias VoiceConverse.Provider.ElevenLabsAgents.{HTTP, MintTransport}

  @signed_url_endpoint "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url"
  @max_backlog_bytes 426_668
  @metadata_timeout_ms 5_000
  @transport_message :elevenlabs_agents_transport

  @spec descriptor() :: VoiceConverse.Provider.descriptor()
  def descriptor do
    %{
      id: :elevenlabs_agents,
      family: :hosted_agent,
      label: "ElevenLabs Agents",
      modes: [:voice, :text],
      needs: [:elevenlabs],
      privacy: %{audio_stored_by_provider: true, deletable?: true},
      price_hint: "provider-priced"
    }
  end

  @spec capabilities() :: VoiceConverse.Provider.capabilities()
  def capabilities do
    %{
      events: [Events.ProviderConversationId, Events.Closed, Events.Error],
      text_only?: false
    }
  end

  @doc "Opens an unlinked daemon-held provider connection."
  @spec open(VoiceConverse.Provider.session_spec()) :: {:ok, pid()} | {:error, Events.Error.t()}
  def open(%{owner: owner, credentials: {credentials, provider_id}} = spec)
      when is_pid(owner) and is_atom(credentials) and is_atom(provider_id) do
    case credential_present?(credentials, provider_id) do
      :present -> GenServer.start(__MODULE__, spec)
      :missing -> {:error, Events.Error.new(:unconfigured, "ElevenLabs is not configured.")}
    end
  end

  def open(_spec), do: {:error, Events.Error.new(:provider_error, "Invalid ElevenLabs session specification.")}

  @spec push_audio(pid(), String.t()) :: :ok
  def push_audio(provider, base64_pcm) when is_binary(base64_pcm), do: cast(provider, {:push_audio, base64_pcm})

  @spec send_context(pid(), String.t()) :: :ok
  def send_context(provider, text) when is_binary(text), do: cast(provider, {:send_context, text})

  @spec send_user_text(pid(), String.t()) :: :ok
  def send_user_text(provider, text) when is_binary(text), do: cast(provider, {:send_user_text, text})

  @spec close(pid()) :: :ok
  def close(provider), do: cast(provider, :close)

  @impl true
  def init(spec) do
    Process.monitor(spec.owner)

    {:ok,
     %{
       owner: spec.owner,
       credentials: spec.credentials,
       agent_id: Map.get(spec, :agent_id),
       system_prompt: spec.system_prompt,
       context: spec.context,
       first_message: spec.first_message,
       voice_id: Map.get(spec, :voice_id),
       audio_out: spec.audio_out,
       http: Map.get(spec, :http, HTTP),
       transport: Map.get(spec, :transport, MintTransport),
       conn: nil,
       ready?: false,
       backlog: [],
       backlog_bytes: 0,
       metadata_timer: nil,
       metadata_timeout: Map.get(spec, :metadata_timeout, @metadata_timeout_ms)
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    with {:ok, key} <- fetch_key(state.credentials),
         {:ok, signed_url} <- fetch_signed_url(state.http, state.agent_id, key) do
      connect_and_initiate(state, signed_url)
    else
      {:error, code} -> fail(state, code, error_message(code))
    end
  end

  @impl true
  def handle_cast({:push_audio, base64_pcm}, %{ready?: true} = state) do
    case send_json(state, %{type: "user_audio_chunk", audio_base_64: base64_pcm}) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  def handle_cast({:push_audio, base64_pcm}, state), do: queue_audio(state, base64_pcm)

  def handle_cast({:send_context, text}, state) do
    case send_json(state, %{type: "contextual_update", text: text}) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  def handle_cast({:send_user_text, text}, state) do
    case send_json(state, %{type: "user_message", text: text}) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  def handle_cast(:close, state) do
    close_transport(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({@transport_message, :text, text}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, frame} -> handle_frame(frame, state)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({@transport_message, :closed}, state), do: close_from_provider(state)

  def handle_info({@transport_message, :closed, close_code}, state), do: close_from_provider(state, close_code)

  def handle_info({@transport_message, :error, _opaque}, state),
    do: fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")

  def handle_info({:DOWN, _monitor, :process, owner, _reason}, %{owner: owner} = state) do
    close_transport(state)
    {:stop, :normal, state}
  end

  def handle_info(:metadata_timeout, %{ready?: false} = state),
    do: fail(state, :provider_unavailable, "ElevenLabs did not initialize the conversation.")

  def handle_info(:metadata_timeout, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_frame(%{"type" => "conversation_initiation_metadata"} = frame, state) do
    metadata = Map.get(frame, "conversation_initiation_metadata_event", frame)
    state = cancel_metadata_timeout(state)

    if is_binary(metadata["conversation_id"]),
      do: emit(state, %Events.ProviderConversationId{id: metadata["conversation_id"]})

    case output_format(metadata) do
      nil ->
        flush_backlog(state)

      format ->
        if(format == atom_format(state.audio_out),
          do: flush_backlog(state),
          else: fail(state, :provider_error, "Voice assistant audio format mismatch.")
        )
    end
  end

  defp handle_frame(%{"type" => "ping"} = frame, state) do
    pong = %{type: "pong"} |> maybe_put(:event_id, Map.get(frame, "event_id"))

    case send_json(state, pong) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  defp handle_frame(%{"type" => type}, state) when is_binary(type) do
    Logger.debug("Ignoring ElevenLabs connection event #{inspect(type)}")
    {:noreply, state}
  end

  defp handle_frame(_frame, state), do: {:noreply, state}

  defp queue_audio(state, base64_pcm) do
    bytes = state.backlog_bytes + byte_size(base64_pcm)

    if bytes <= @max_backlog_bytes do
      {:noreply, %{state | backlog: [base64_pcm | state.backlog], backlog_bytes: bytes}}
    else
      fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  defp flush_backlog(state) do
    backlog = Enum.reverse(state.backlog)
    state = %{state | ready?: true, backlog: [], backlog_bytes: 0}

    Enum.reduce_while(backlog, {:ok, state}, fn audio, {:ok, state} ->
      case send_json(state, %{type: "user_audio_chunk", audio_base_64: audio}) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} -> {:halt, {:error, state}}
      end
    end)
    |> case do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  defp close_from_provider(state, close_code \\ nil) do
    reason = close_reason(state.ready?, close_code)
    emit(state, %Events.Closed{reason: reason})
    {:stop, :normal, state}
  end

  defp connect_and_initiate(state, signed_url) do
    case connect(state.transport, signed_url) do
      {:ok, conn} ->
        state = %{state | conn: conn}

        case send_json(state, initiation_frame(state)) do
          {:ok, state} -> {:noreply, start_metadata_timeout(state)}
          {:error, _opaque} -> fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
        end

      {:error, _opaque} ->
        fail(state, :provider_unavailable, "ElevenLabs connection is unavailable.")
    end
  end

  defp fail(state, code, message) do
    state = cancel_metadata_timeout(state)
    emit(state, Events.Error.new(code, message))
    close_transport(state)
    emit(state, %Events.Closed{reason: code})
    {:stop, :normal, state}
  end

  defp fetch_signed_url(http, agent_id, key) do
    url = signed_url_endpoint(agent_id)

    case http_get(http, url, headers: [{"xi-api-key", key}], receive_timeout: 5_000) do
      {:ok, 200, body} -> signed_url_from(body)
      {:ok, status, _body} -> {:error, http_error_code(status)}
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  rescue
    _error -> {:error, :provider_unavailable}
  catch
    _kind, _reason -> {:error, :provider_unavailable}
  end

  defp signed_url_from(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"signed_url" => url}} when is_binary(url) -> {:ok, url}
      _otherwise -> {:error, :provider_error}
    end
  end

  defp signed_url_from(_body), do: {:error, :provider_error}

  defp http_get(http, url, opts) when is_function(http, 2), do: http.(url, opts)
  defp http_get(http, url, opts), do: http.get(url, opts)

  defp connect(transport, url) when is_function(transport, 2), do: transport.(url, [])
  defp connect(transport, url), do: transport.connect(url, [])

  defp send_json(%{conn: nil}, _frame), do: {:error, :not_connected}

  defp send_json(state, frame) do
    case state.transport.send_text(state.conn, Jason.encode!(frame)) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :send_failed}
  catch
    _kind, _reason -> {:error, :send_failed}
  end

  defp close_transport(%{conn: nil}), do: :ok

  defp close_transport(state) do
    state.transport.close(state.conn)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp initiation_frame(state) do
    agent =
      %{prompt: %{prompt: state.system_prompt <> "\n\n" <> state.context}}
      |> maybe_put(:first_message, state.first_message)

    override = %{agent: agent} |> maybe_put_tts_voice(state.voice_id)

    %{type: "conversation_initiation_client_data", conversation_config_override: override}
  end

  defp maybe_put_tts_voice(frame, nil), do: frame
  defp maybe_put_tts_voice(frame, voice_id), do: Map.put(frame, :tts, %{voice_id: voice_id})
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp output_format(metadata),
    do: metadata["agent_output_audio_format"] || metadata["output_format"]

  defp atom_format(format) when is_atom(format), do: Atom.to_string(format)
  defp atom_format(format), do: format

  defp signed_url_endpoint(nil), do: @signed_url_endpoint
  defp signed_url_endpoint(agent_id), do: @signed_url_endpoint <> "?" <> URI.encode_query(%{"agent_id" => agent_id})

  defp http_error_code(status) when status in [401, 403], do: :provider_auth
  defp http_error_code(429), do: :provider_quota
  defp http_error_code(status) when status >= 500, do: :provider_unavailable
  defp http_error_code(_status), do: :provider_error

  defp fetch_key({credentials, provider_id}) do
    case credentials.fetch(provider_id, :connect) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _otherwise -> {:error, :provider_auth}
    end
  rescue
    _error -> {:error, :provider_auth}
  catch
    _kind, _reason -> {:error, :provider_auth}
  end

  defp credential_present?(credentials, provider_id) do
    case credentials.fetch(provider_id, :probe) do
      {:ok, :present} -> :present
      _otherwise -> :missing
    end
  rescue
    _error -> :missing
  catch
    _kind, _reason -> :missing
  end

  defp error_message(:provider_auth), do: "ElevenLabs authentication failed."
  defp error_message(:provider_quota), do: "ElevenLabs quota is unavailable."
  defp error_message(:provider_error), do: "ElevenLabs returned an invalid response."
  defp error_message(:provider_unavailable), do: "ElevenLabs connection is unavailable."

  defp start_metadata_timeout(state) do
    %{state | metadata_timer: Process.send_after(self(), :metadata_timeout, state.metadata_timeout)}
  end

  defp cancel_metadata_timeout(%{metadata_timer: nil} = state), do: state

  defp cancel_metadata_timeout(state) do
    Process.cancel_timer(state.metadata_timer)
    %{state | metadata_timer: nil}
  end

  defp close_reason(false, _close_code), do: :provider_error
  defp close_reason(true, nil), do: :normal
  defp close_reason(true, close_code), do: {:provider_closed, close_code}

  defp emit(state, event), do: send(state.owner, {:voice_conversation, self(), event})

  defp cast(provider, message) do
    GenServer.cast(provider, message)
  catch
    :exit, _reason -> :ok
  end
end
