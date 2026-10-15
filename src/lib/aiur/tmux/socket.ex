defmodule Aiur.Tmux.Socket do
  @moduledoc "Socket selection for REPL calls; daemon chat calls retain their default server."

  alias Aiur.Tmux.{Exec, Layout}

  @type server :: GenServer.server() | {:socket, GenServer.server(), String.t()}

  @spec agents() :: server()
  def agents do
    socket = System.get_env("AIUR_AGENT_TMUX_SOCKET") || derived_agent_socket()
    if socket, do: {:socket, Aiur.Tmux, socket}, else: Aiur.Tmux
  end

  @spec name(term()) :: String.t() | nil
  def name({:socket, _server, socket}), do: socket
  def name(_server), do: System.get_env("AIUR_TMUX_SOCKET")

  @spec pane_ref(term(), String.t()) :: tuple()
  def pane_ref({:socket, _server, socket}, pane_id), do: {:pane, pane_id, socket}
  def pane_ref(_server, pane_id), do: {:pane, pane_id}

  @spec call(server(), term(), timeout()) :: term()
  def call(server, message, timeout \\ 5_000)
  def call({:socket, server, socket}, message, timeout), do: GenServer.call(server, {:on_socket, socket, message}, timeout)
  def call(server, message, timeout), do: GenServer.call(server, message, timeout)

  @spec configure(map()) :: :ok | {:error, term()}
  def configure(%{transport: :shell, socket: socket} = state) do
    if String.ends_with?(socket, "-agents") do
      with {:ok, _} <- Exec.run_args(state, ["bind-key", "-n", "C-c", "send-keys", "C-c"]), {:ok, _} <- Exec.run_args(state, ["bind-key", "-n", "C-q", "detach-client"]), do: :ok
    else
      :ok
    end
  end

  def configure(_state), do: :ok

  @spec kill_pane(String.t() | {String.t(), String.t()}) :: :ok | {:error, term()}
  def kill_pane({pane_id, socket}), do: Layout.kill_pane(%{transport: :shell, socket: socket}, pane_id)
  def kill_pane(pane_id), do: Aiur.Tmux.kill_pane(pane_id)

  @spec attach_command(map()) :: String.t() | nil
  def attach_command(%{repl_pane_id: pane, repl_tmux_socket: socket}) when is_binary(pane) and is_binary(socket) do
    quote = fn value -> "'" <> String.replace(value, "'", "'\\''") <> "'" end
    "tmux -L #{quote.(socket)} select-pane -t #{quote.(pane)} \\; attach-session"
  end

  def attach_command(_entry), do: nil

  defp derived_agent_socket do
    case System.get_env("AIUR_TMUX_SOCKET") do
      socket when is_binary(socket) and socket != "" -> socket <> "-agents"
      _ -> nil
    end
  end
end
