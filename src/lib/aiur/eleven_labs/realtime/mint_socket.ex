defmodule Aiur.ElevenLabs.Realtime.MintSocket do
  @moduledoc """
  A single `Mint.WebSocket` connection owned by its own process.

  Mint delivers socket data as messages to whichever process owns the
  connection. Giving the connection its own process keeps `Mint` out of
  `Aiur.ElevenLabs.Realtime` entirely, so the session's rules are exercised
  against a fake transport and nothing in the test suite opens a socket.

  The process monitors the session that opened it and stops when that session
  stops, so a connection cannot outlive the utterance it was opened for.

  Nothing here logs. A Mint error value can embed the request that produced it,
  and the request carries the `xi-api-key` header.
  """

  use GenServer

  @connect_timeout_ms 10_000

  # The state is declared rather than left to inference, and so is the fold's
  # accumulator. The upgrade response is folded with `Enum.reduce_while/3`, whose
  # own return type is opaque, so without these dialyzer cannot see that `status`
  # is populated by one clause before another reads it — it takes the `nil` from
  # `init/1` as the only possible value and concludes that the success branch of
  # `Mint.WebSocket.new/4` is unreachable.
  @typep state :: %{
           session: pid(),
           conn: Mint.HTTP.t(),
           ref: Mint.Types.request_ref(),
           websocket: Mint.WebSocket.t() | nil,
           pending: [binary()],
           status: Mint.Types.status() | nil,
           headers: Mint.Types.headers()
         }

  @typep fold :: {:noreply, state()} | {:stop, :normal, state()}

  @spec start(pid(), String.t(), [{String.t(), String.t()}]) :: {:ok, pid()} | {:error, term()}
  def start(session, url, headers) do
    GenServer.start(__MODULE__, {session, url, headers})
  end

  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(socket, text), do: GenServer.call(socket, {:send_text, text})

  @spec close(pid()) :: :ok
  def close(socket) do
    GenServer.stop(socket, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({session, url, headers}) do
    Process.monitor(session)

    with {:ok, target} <- target(url),
         {:ok, conn} <- Mint.HTTP.connect(target.scheme, target.host, target.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(target.ws_scheme, conn, target.path, headers) do
      # `status` and `headers` are declared here rather than stashed on arrival:
      # the upgrade response is folded across three clauses, and a key that only
      # exists once one of them has run leaves the others reading a map that
      # does not have it. Declaring them keeps the state one shape throughout.
      {:ok, %{session: session, conn: conn, ref: ref, websocket: nil, pending: [], status: nil, headers: []}, @connect_timeout_ms}
    else
      # The reason is replaced rather than propagated: the caller renders nothing
      # from it, and the value can carry the request headers.
      _unreachable -> {:stop, :connect_failed}
    end
  end

  @impl true
  def handle_call({:send_text, _text}, _from, %{websocket: nil} = state), do: {:reply, {:error, :not_ready}, state}

  def handle_call({:send_text, text}, _from, state) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, {:text, text}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:reply, :ok, %{state | websocket: websocket, conn: conn}}
    else
      _unreachable -> {:reply, {:error, :send_failed}, state}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    notify(state, {:elevenlabs_transport, :error, :handshake_timeout})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state), do: {:stop, :normal, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> Enum.reduce_while(responses, {:noreply, %{state | conn: conn}}, &handle_response/2)
      {:error, conn, _reason, _responses} -> transport_failed(%{state | conn: conn})
      :unknown -> {:noreply, state}
    end
  end

  @spec handle_response(Mint.Types.response(), fold()) :: {:cont, fold()} | {:halt, fold()}
  defp handle_response({:status, ref, status}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | status: status}}}

  defp handle_response({:headers, ref, headers}, {:noreply, %{ref: ref} = state}),
    do: {:cont, {:noreply, %{state | headers: headers}}}

  # `:done` closes the HTTP upgrade exchange and is where the websocket comes
  # into existence — so it is also where anything already buffered gets decoded.
  defp handle_response({:done, ref}, {:noreply, %{ref: ref} = state}) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.headers) do
      {:ok, conn, websocket} ->
        {pending, state} = {Enum.reverse(state.pending), %{state | conn: conn, websocket: websocket, pending: []}}
        {:cont, Enum.reduce_while(pending, {:noreply, state}, &decode_frames/2)}

      {:error, conn, _reason} ->
        {:halt, transport_failed(%{state | conn: conn})}
    end
  end

  # Server frames can share the upgrade's response batch.
  #
  # Mint hands back `[:status, :headers, :data, :done]` in one list when the
  # server's first websocket frame lands in the same TCP segment as its 101 —
  # which ElevenLabs does every time, because `session_started` is sent
  # immediately on accept. The websocket only exists from `:done` onward, so
  # decoding in arrival order would drop that frame, the readiness gate would
  # never open, and the whole hold would queue in the backlog and be discarded.
  # Buffering until the websocket exists is what makes the first word survive.
  defp handle_response({:data, ref, data}, {:noreply, %{ref: ref, websocket: nil} = state}),
    do: {:cont, {:noreply, %{state | pending: [data | state.pending]}}}

  defp handle_response({:data, ref, data}, {:noreply, %{ref: ref} = state}), do: decode_frames(data, {:noreply, state})

  defp handle_response({:error, ref, _reason}, {:noreply, %{ref: ref} = state}), do: {:halt, transport_failed(state)}
  defp handle_response(_response, acc), do: {:cont, acc}

  @spec decode_frames(binary(), fold()) :: {:cont, fold()} | {:halt, fold()}
  defp decode_frames(data, {:noreply, state}) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> {:cont, deliver(%{state | websocket: websocket}, frames)}
      {:error, websocket, _reason} -> {:halt, transport_failed(%{state | websocket: websocket})}
    end
  end

  defp decode_frames(_data, acc), do: {:halt, acc}

  defp deliver(state, frames) do
    Enum.reduce_while(frames, {:noreply, state}, fn
      {:text, text}, {:noreply, state} ->
        notify(state, {:elevenlabs_transport, :text, text})
        {:cont, {:noreply, state}}

      {:close, _code, _reason}, {:noreply, state} ->
        notify(state, {:elevenlabs_transport, :closed})
        {:halt, {:stop, :normal, state}}

      _frame, acc ->
        {:cont, acc}
    end)
  end

  defp transport_failed(state) do
    notify(state, {:elevenlabs_transport, :error, :transport})
    {:stop, :normal, state}
  end

  defp notify(state, message), do: send(state.session, message)

  defp target(url) do
    uri = URI.parse(url)

    case uri.scheme do
      scheme when scheme in ["wss", "https"] -> {:ok, describe(uri, :https, :wss, 443)}
      scheme when scheme in ["ws", "http"] -> {:ok, describe(uri, :http, :ws, 80)}
      _unsupported -> {:error, :unsupported_scheme}
    end
  end

  defp describe(uri, scheme, ws_scheme, default_port) do
    %{
      scheme: scheme,
      ws_scheme: ws_scheme,
      host: uri.host,
      port: uri.port || default_port,
      path: path(uri)
    }
  end

  defp path(%URI{path: path, query: nil}), do: path || "/"
  defp path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query
end
