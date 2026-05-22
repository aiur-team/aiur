defmodule Aiur.Opencode.HiddenWindow do
  @moduledoc """
  Owns the lifetime of the hidden tmux window where all `opencode attach`
  slot panes live when they are not currently visible.

  Created once at boot (no external dependency) with a no-op keep-alive
  pane (`sleep infinity`) so the window survives even when no slot
  panes are attached yet. Slot workers call `Tmux.split_pane/6` against
  the keep-alive pane (with `silent: true`) to spawn their hidden attach.

  Idempotent: a supervisor restart finds the window already there and
  reuses it.
  """

  use GenServer
  require Logger

  alias Aiur.Opencode.Config
  alias Aiur.Tmux

  @window_name "aiur-hidden"
  @keep_alive_cmd "sleep infinity"

  defstruct status: :waiting, window_name: nil, keep_alive_pane_id: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Compile-time name of the hidden tmux window."
  @spec window_name() :: String.t()
  def window_name, do: @window_name

  @doc """
  Synchronously ensure the hidden window exists. Returns `:ok` if the
  window is up, otherwise `{:error, reason}`.
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
      state = %__MODULE__{status: :waiting, window_name: @window_name}
      {:ok, state, {:continue, :create_window}}
    end
  end

  @impl true
  def handle_continue(:create_window, state) do
    case Tmux.new_hidden_window(state.window_name, @keep_alive_cmd) do
      {:ok, pane_id} ->
        Logger.info("opencode_hidden_window phase=ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} window=#{state.window_name} keep_alive_pane=#{pane_id}")

        {:noreply, %{state | status: :ready, keep_alive_pane_id: pane_id}}

      {:error, reason} ->
        Logger.warning("opencode_hidden_window phase=create_failed elapsed_ms=#{Aiur.Boot.elapsed_ms()} window=#{state.window_name} reason=#{inspect(reason)}")

        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
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
