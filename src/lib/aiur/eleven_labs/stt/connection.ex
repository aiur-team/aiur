defmodule Aiur.ElevenLabs.STT.Connection do
  @moduledoc "WebSocket transport boundary for a realtime STT session."

  use WebSockex

  require Logger

  @type state :: %{owner: pid()}

  @spec open(String.t(), String.t(), pid(), pos_integer()) :: {:ok, pid()} | {:error, term()}
  def open(url, api_key, owner, connect_timeout_ms) do
    with {:ok, uri} <- WebSockex.Conn.parse_url(url),
         true <- uri.scheme in ["ws", "wss"] and is_binary(uri.host) do
      options = [
        extra_headers: [{"xi-api-key", api_key}],
        socket_connect_timeout: connect_timeout_ms,
        socket_recv_timeout: connect_timeout_ms
      ]

      options =
        if uri.scheme == "wss" do
          Keyword.put(options, :ssl_options,
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(uri.host),
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          )
        else
          options
        end

      uri
      |> WebSockex.Conn.new(options)
      |> WebSockex.start_link(__MODULE__, %{owner: owner}, handle_initial_conn_failure: true)
    else
      _invalid -> {:error, :invalid_base_url}
    end
  end

  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(conn, payload) do
    WebSockex.send_frame(conn, {:text, payload})
  catch
    :exit, reason -> {:error, reason}
  end

  @spec shutdown(pid() | nil) :: :ok
  def shutdown(conn) when is_pid(conn) do
    if Process.alive?(conn), do: WebSockex.cast(conn, :shutdown)
    :ok
  end

  def shutdown(_conn), do: :ok

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:stt_connection, self(), :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, data}, state) do
    send(state.owner, {:stt_connection, self(), {:text, data}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:shutdown, state), do: {:close, state}

  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.owner, {:stt_connection, self(), {:disconnected, status.reason}})
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    unless orderly_close?(reason), do: Logger.warning("voice dictation: speech-to-text socket stopped: #{inspect(reason)}")
    :ok
  end

  defp orderly_close?(:normal), do: true
  defp orderly_close?({:local, :normal}), do: true
  defp orderly_close?({:remote, code, _reason}) when code in [1000, 1001], do: true
  defp orderly_close?(_reason), do: false
end
