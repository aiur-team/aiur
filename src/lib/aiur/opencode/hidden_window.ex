defmodule Aiur.Opencode.HiddenWindow do
  @moduledoc """
  Owns the lifetime of the hidden tmux window where all `opencode attach`
  slot panes live when they are not currently visible.

  Created once at boot (no external dependency) with a no-op keep-alive
  pane (a long `sleep`) so the window survives even when no slot
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
  # `sleep infinity` is GNU-only — BSD/macOS sleep rejects it and the pane
  # exits immediately, so tmux closes the hidden window's only pane mid-boot.
  # A large integer sleep is portable across BSD and GNU (~68 years).
  @keep_alive_cmd "sleep 2147483647"

  defstruct status: :waiting, window_name: nil, keep_alive_pane_id: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Compile-time name of the hidden tmux window."
  @spec window_name() :: String.t()
  def window_name, do: @window_name

  @doc "Keep-alive command run in the hidden window's sentinel pane."
  @spec keep_alive_command() :: String.t()
  def keep_alive_command, do: @keep_alive_cmd

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
        size_to_visible_geometry(state.window_name)

        Logger.info("opencode_hidden_window phase=ready elapsed_ms=#{Aiur.Boot.elapsed_ms()} window=#{state.window_name} keep_alive_pane=#{pane_id}")

        {:noreply, %{state | status: :ready, keep_alive_pane_id: pane_id}}

      {:error, reason} ->
        Logger.warning("opencode_hidden_window phase=create_failed elapsed_ms=#{Aiur.Boot.elapsed_ms()} window=#{state.window_name} reason=#{inspect(reason)}")

        {:noreply, %{state | status: :failed}}
    end
  end

  # Pre-size the hidden window so each slot's attach pane lands at the
  # SAME geometry it will eventually have in window 0 once the user
  # opens it. Avoids the SIGWINCH that triggers opencode-attach's
  # ~7 s splash animation on every move-pane resize (observed: pane
  # appears in 64 ms but opencode TUI takes 7 s to repaint because the
  # hidden pane was 600 cols wide and the visible split is 67-100 cols).
  #
  # Target = first-chat geometry: agent_list + 1 chat = 50/50 split of
  # window 0. Hidden window width = chat_pane_width × slot_count so each
  # hidden pane = chat_pane_width once even-horizontal splits them.
  defp size_to_visible_geometry(window_name) do
    with {:ok, [dims_str | _]} <-
           Tmux.command(
             Tmux,
             "display-message -p -t aiur-orangekid-default:0 \"\#{window_width} \#{window_height}\""
           ),
         [w_str, h_str] <- String.split(String.trim(dims_str), " ", trim: true),
         {term_w, ""} <- Integer.parse(w_str),
         {term_h, ""} <- Integer.parse(h_str) do
      slot_count = safe_slot_count()
      chat_pane_width = max(div(term_w, 2), 40)
      hidden_window_w = chat_pane_width * slot_count

      _ =
        Tmux.command(
          Tmux,
          "resize-window -t aiur-orangekid-default:#{window_name} -x #{hidden_window_w} -y #{term_h}"
        )

      Aiur.Perf.event(:hidden_window_resized,
        terminal_w: term_w,
        terminal_h: term_h,
        chat_pane_width: chat_pane_width,
        hidden_window_w: hidden_window_w,
        slot_count: slot_count
      )
    else
      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_slot_count do
    pre_warmed = Aiur.Config.pre_warmed_sessions()
    max_agents = Aiur.Config.max_concurrent_agents()
    max(min(pre_warmed, max_agents), 1)
  rescue
    _ -> 3
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
