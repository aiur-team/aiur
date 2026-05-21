defmodule Aiur.Opencode.HiddenWindow do
  @moduledoc """
  Owns the lifetime of the hidden tmux window where all background
  `opencode attach` panes live until the user opens them.

  At boot, listens for `Aiur.Opencode.WarmServer`'s `:warm_server_ready`
  broadcast, then creates the window once with a no-op keep-alive pane
  (`sleep infinity`) so the window survives even when no agent panes
  are attached yet.

  Other modules:
  - `Aiur.Opencode.AgentAttach` reads `window_name/0` to target the
    window when spawning per-agent opencode-attach panes.
  - `Aiur.Tmux.move_pane_hidden/2` and `move_pane_visible/2` use the
    name as the target/source for visibility swaps.

  Idempotent: a restart finds the window already there and reuses it.
  """

  use GenServer
  require Logger

  alias Aiur.Opencode.Config
  alias Aiur.Tmux

  @ready_topic "opencode:warm"
  @window_name "aiur-hidden"
  @keep_alive_cmd "sleep infinity"

  defstruct status: :waiting, window_name: nil, keep_alive_pane_id: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Compile-time name of the hidden tmux window."
  @spec window_name() :: String.t()
  def window_name, do: @window_name

  @doc """
  Synchronously ensure the hidden window exists. Returns `:ok` once it
  has been created by the GenServer's boot path, or `{:error, reason}`
  if the GenServer is unreachable or window creation fails.

  Used by `Aiur.Opencode.AttachQueue.init` before processing identifiers
  so the queue never races the window-creation step.
  """
  @spec ensure(timeout()) :: :ok | {:error, term()}
  def ensure(timeout \\ 10_000) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :ensure, timeout)
    else
      {:error, :not_started}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec status() :: :waiting | :ready | :failed | :disabled
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status, 200)
    else
      :disabled
    end
  catch
    :exit, _ -> :disabled
  end

  @impl true
  def init(_opts) do
    if Config.prewarm_disabled?() do
      :ignore
    else
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, @ready_topic)
      {:ok, %__MODULE__{status: :waiting, window_name: @window_name}}
    end
  end

  @impl true
  def handle_info({:warm_server_ready, _base_url}, %{status: :waiting} = state) do
    case Tmux.new_hidden_window(state.window_name, @keep_alive_cmd) do
      {:ok, pane_id} ->
        Logger.info(
          "opencode_hidden_window phase=ready window=#{state.window_name} keep_alive_pane=#{pane_id}"
        )

        {:noreply, %{state | status: :ready, keep_alive_pane_id: pane_id}}

      {:error, reason} ->
        Logger.warning(
          "opencode_hidden_window create_failed window=#{state.window_name} reason=#{inspect(reason)}"
        )

        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_info({:warm_server_ready, _base_url}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:ensure, _from, %{status: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:ensure, _from, %{status: :failed} = state) do
    {:reply, {:error, :hidden_window_create_failed}, state}
  end

  def handle_call(:ensure, _from, state) do
    {:reply, {:error, :hidden_window_not_ready_yet}, state}
  end
end
