defmodule VoiceConverse.Provider.ElevenLabsAgents.MintSocket do
  @moduledoc false

  use GenServer

  @message_tag :elevenlabs_agents_transport
  @handshake_timeout_ms 5_000
  @max_pending_bytes 426_668

  @spec start(pid(), String.t(), [{String.t(), String.t()}]) :: {:ok, pid()} | {:error, term()}
  def start(session, url, headers) do
    with {:ok, socket} <- GenServer.start(__MODULE__, session) do
      # The one-time signed URL arrives after the process has started, so it
      # cannot appear in an init crash report or in its long-lived state.
      GenServer.cast(socket, {:connect, url, headers})
      {:ok, socket}
    end
  end

  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(socket, text) do
    GenServer.call(socket, {:send_text, text})
  catch
    :exit, _reason -> {:error, :send_failed}
  end

  @spec close(pid()) :: :ok
  def close(socket) do
    GenServer.call(socket, :close)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec tls_options(String.t()) :: keyword()
  def tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @impl true
  def init(session) do
    Process.monitor(session)

    {:ok,
     %{
       session: session,
       conn: nil,
       ref: nil,
       websocket: nil,
       pending: [],
       pending_bytes: 0,
       outbound: [],
       outbound_bytes: 0,
       status: nil,
       headers: [],
       handshake_timer: nil
     }}
  end

  @impl true
  def handle_cast({:connect, url, headers}, state) do
    with {:ok, target} <- target(url),
         {:ok, conn} <- connect(target),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, headers) do
      timer = Process.send_after(self(), :handshake_timeout, @handshake_timeout_ms)
      {:noreply, %{state | conn: conn, ref: ref, handshake_timer: timer}}
    else
      _connect_failed -> transport_failed(state)
    end
  end

  @impl true
  def handle_call({:send_text, text}, _from, %{websocket: nil} = state) do
    bytes = state.outbound_bytes + byte_size(text)

    if bytes <= @max_pending_bytes do
      {:reply, :ok, %{state | outbound: [text | state.outbound], outbound_bytes: bytes}}
    else
      {:stop, :normal, {:error, :not_ready}, notify_transport_failed(state)}
    end
  end

  def handle_call({:send_text, text}, _from, state) do
    case send_frame(state, {:text, text}) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:stop, :normal, {:error, :send_failed}, notify_transport_failed(state)}
    end
  end

  def handle_call(:close, _from, state) do
    state = send_close_frame(state, 1_000, "")
    close_connection(state.conn)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:handshake_timeout, %{websocket: nil} = state), do: transport_failed(state)
  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> process_responses(responses, %{state | conn: conn})
      {:error, conn, _reason, _responses} -> transport_failed(%{state | conn: conn})
      :unknown -> {:noreply, state}
    end
  end

  defp process_responses([], state), do: {:noreply, state}

  defp process_responses([{:status, ref, status} | responses], %{ref: ref} = state),
    do: process_responses(responses, %{state | status: status})

  defp process_responses([{:headers, ref, headers} | responses], %{ref: ref} = state),
    do: process_responses(responses, %{state | headers: headers})

  defp process_responses([{:data, ref, data} | responses], %{ref: ref, websocket: nil} = state) do
    bytes = state.pending_bytes + byte_size(data)

    if bytes <= @max_pending_bytes do
      process_responses(responses, %{state | pending: [data | state.pending], pending_bytes: bytes})
    else
      transport_failed(state)
    end
  end

  defp process_responses([{:data, ref, data} | responses], %{ref: ref} = state) do
    case decode_frames(data, state) do
      {:ok, state} -> process_responses(responses, state)
      {:closed, state} -> {:stop, :normal, state}
      {:error, state} -> transport_failed(state)
    end
  end

  defp process_responses([{:done, ref} | responses], %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.headers) do
      {:ok, conn, websocket} ->
        cancel_timer(state.handshake_timer)
        state = %{state | conn: conn, websocket: websocket, handshake_timer: nil}

        with {:ok, state} <- decode_pending(state),
             {:ok, state} <- flush_outbound(state) do
          process_responses(responses, state)
        else
          {:closed, state} -> {:stop, :normal, state}
          {:error, state} -> transport_failed(state)
        end

      {:error, conn, _reason} ->
        transport_failed(%{state | conn: conn})
    end
  end

  defp process_responses([{:error, ref, _reason} | _responses], %{ref: ref} = state), do: transport_failed(state)
  defp process_responses([_response | responses], state), do: process_responses(responses, state)

  defp decode_pending(state) do
    state.pending
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, %{state | pending: [], pending_bytes: 0}}, fn data, {:ok, state} ->
      case decode_frames(data, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        result -> {:halt, result}
      end
    end)
  end

  defp flush_outbound(state) do
    state.outbound
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, %{state | outbound: [], outbound_bytes: 0}}, fn text, {:ok, state} ->
      case send_frame(state, {:text, text}) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, state} -> {:halt, {:error, state}}
      end
    end)
  end

  defp decode_frames(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> deliver(%{state | websocket: websocket}, frames)
      {:error, websocket, _reason} -> {:error, %{state | websocket: websocket}}
    end
  end

  defp deliver(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn
      {:text, text}, {:ok, state} ->
        send(state.session, {@message_tag, :text, text})
        {:cont, {:ok, state}}

      {:ping, data}, {:ok, state} ->
        case send_frame(state, {:pong, data}) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, state} -> {:halt, {:error, state}}
        end

      {:close, code, reason}, {:ok, state} ->
        state = send_close_frame(state, code || 1_000, reason || "")
        send(state.session, {@message_tag, :closed, code})
        {:halt, {:closed, state}}

      _frame, result ->
        {:cont, result}
    end)
  end

  defp send_close_frame(%{websocket: nil} = state, _code, _reason), do: state

  defp send_close_frame(state, code, reason) do
    case send_frame(state, {:close, code, reason}) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      _send_failed -> {:error, state}
    end
  end

  defp transport_failed(state), do: {:stop, :normal, notify_transport_failed(state)}

  defp notify_transport_failed(state) do
    cancel_timer(state.handshake_timer)
    close_connection(state.conn)
    send(state.session, {@message_tag, :error, :transport})
    %{state | handshake_timer: nil}
  end

  defp connect(%{scheme: :https, host: host, port: port}),
    do: Mint.HTTP.connect(:https, host, port, protocols: [:http1], transport_opts: tls_options(host))

  defp connect(%{scheme: :http, host: host, port: port}),
    do: Mint.HTTP.connect(:http, host, port, protocols: [:http1])

  defp close_connection(nil), do: :ok
  defp close_connection(conn), do: Mint.HTTP.close(conn)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp target(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["wss", "https"] and is_binary(host) ->
        {:ok, %{scheme: :https, ws_scheme: :wss, host: host, port: uri.port || 443, path: path(uri)}}

      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "http"] and is_binary(host) ->
        {:ok, %{scheme: :http, ws_scheme: :ws, host: host, port: uri.port || 80, path: path(uri)}}

      _unsupported ->
        {:error, :unsupported_url}
    end
  end

  defp path(%URI{path: path, query: nil}), do: path || "/"
  defp path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query
end
