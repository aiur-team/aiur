defmodule Aiur.Opencode.Slot do
  @moduledoc """
  Per-slot opencode instance. One Slot worker owns one opencode-serve
  process + one opencode-attach tmux pane for the lifetime of an aiur
  run.

  ## State machine

      :booting          → materialize workspace
                        → register in SlotRegistry
                        → handle_continue(:start_serve)
      :serve_starting   → wait for Aiur.Opencode.Server :ready
                        → handle_continue(:spawn_attach)
      :attach_spawning  → tmux split_pane into hidden window (silent)
                        → broadcast {:slot_ready, slot_index} on "opencode:slots"
                        → status = :ready
      :ready            → idle, accepting Slot.select/2 calls
      :active           → an agent's session is currently displayed
                          (active_identifier set, poll loop running)

  When `Slot.deselect/1` is called the worker returns to `:ready` —
  the opencode-serve and attach pane stay alive; only the active
  session selection clears.

  ## Polling for external session changes

  When `:active`, the Slot polls opencode periodically (default 500ms)
  to detect Ctrl+P-initiated session switches. The actual probe
  endpoint is resolved during U10 of the slot-bound plan; until then
  the poll loop runs but only broadcasts changes when `Slot.select/2`
  is called (Aiur-initiated). External-switch detection is wired in U10.

  ## Token generation overlap

  The Slot bumps `generation` every time it would restart its
  opencode-serve. Tokens are registered against `{slot_index, generation}`,
  and `delete_stale/2` is called only after the new attach is ready —
  so chat-completion requests arriving mid-restart never see an empty
  registry window.
  """

  use GenServer
  require Logger

  alias Aiur.Boot

  alias Aiur.Opencode.{
    ApiClient,
    Config,
    HiddenWindow,
    Protocol,
    Server,
    SessionGC,
    SessionWriter,
    SessionWriterRegistry,
    SlotRegistry,
    TokenRegistry,
    WorkspaceSetup
  }

  alias Aiur.Tmux

  @slots_topic "opencode:slots"
  @hidden_split_percent 50
  @default_poll_interval_ms 500

  defstruct slot_index: nil,
            status: :booting,
            workspace_path: nil,
            server_pid: nil,
            base_url: nil,
            token: nil,
            generation: 1,
            pane_id: nil,
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: nil

  @type status :: :booting | :serve_starting | :attach_spawning | :ready | :active | :failed

  # --- Public API -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    slot_index = Keyword.fetch!(opts, :slot_index)
    GenServer.start_link(__MODULE__, opts, name: process_name(slot_index))
  end

  @doc "PubSub topic for slot lifecycle events."
  @spec slots_topic() :: String.t()
  def slots_topic, do: @slots_topic

  @doc """
  Select an agent's session in this slot. Drives:

  1. `SessionWriterRegistry.ensure/2` for the identifier (history replay)
  2. `ApiClient.select_session/2` to switch the TUI
  3. A best-effort bridge nudge so opencode re-fetches the new rows
  4. Starts the active-session poll loop
  5. Broadcasts `{:slot_session_changed, slot_index, identifier}` on the
     PubSub topic so AgentList can update the circle indicator

  Returns `{:ok, pane_id}` so PaneManager can move the pane to visible.
  """
  @spec select(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def select(server, identifier, timeout \\ 15_000)
      when is_binary(identifier) do
    GenServer.call(server, {:select, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Release the active identifier. The slot returns to `:ready`. The
  opencode-serve and tmux attach pane stay alive.
  """
  @spec deselect(GenServer.server()) :: :ok
  def deselect(server) do
    GenServer.call(server, :deselect, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Lightweight introspection — current status + identifier + pane_id."
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server) do
    GenServer.call(server, :snapshot, 2_000)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    slot_index = Keyword.fetch!(opts, :slot_index)
    Process.flag(:trap_exit, true)

    case SlotRegistry.register_self(slot_index) do
      :ok ->
        Logger.info(
          "opencode_slot phase=init elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}"
        )

        state = %__MODULE__{
          slot_index: slot_index,
          status: :booting,
          workspace_path: workspace_path_for(slot_index)
        }

        {:ok, state, {:continue, :start_serve}}

      {:error, :already_registered} ->
        Logger.warning(
          "opencode_slot phase=duplicate elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}"
        )

        :ignore
    end
  end

  @impl true
  def handle_continue(:start_serve, state) do
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"
    agent_ids = active_agent_identifiers()

    with :ok <- File.mkdir_p(state.workspace_path),
         {:ok, token} <-
           WorkspaceSetup.materialize_slot(
             state.workspace_path,
             bridge_url,
             agent_ids,
             state.slot_index,
             state.generation
           ),
         {:ok, server_pid} <-
           Server.start_link(%{
             identifier: "_slot-#{state.slot_index}",
             workspace: state.workspace_path
           }),
         {:ok, base_url, _os_pid} <- Server.await_ready(server_pid) do
      Logger.info(
        "opencode_slot phase=serve_ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} base_url=#{base_url}"
      )

      new_state = %{
        state
        | status: :attach_spawning,
          server_pid: server_pid,
          base_url: base_url,
          token: token
      }

      {:noreply, new_state, {:continue, :spawn_attach}}
    else
      error ->
        Logger.warning(
          "opencode_slot phase=serve_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}"
        )

        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_continue(:spawn_attach, state) do
    with {:ok, keep_alive_pane} <- hidden_window_target(),
         attach_cmd = Protocol.attach_command(state.base_url),
         {:ok, pane_id} <-
           Tmux.split_pane(
             Tmux,
             keep_alive_pane,
             :horizontal,
             @hidden_split_percent,
             attach_cmd,
             silent: true
           ) do
      Logger.info(
        "opencode_slot phase=ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} pane_id=#{pane_id}"
      )

      Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, state.slot_index})

      # First slot to reach :ready runs boot-time GC. Recovers from any
      # prior aiur run that crashed before its shutdown could reap
      # sessions (kill -9, BEAM panic, OOM). Lifted from WarmServer.
      if state.slot_index == 1 do
        Task.start(fn -> SessionGC.run(state.base_url) end)
      end

      {:noreply, %{state | status: :ready, pane_id: pane_id}}
    else
      error ->
        Logger.warning(
          "opencode_slot phase=attach_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}"
        )

        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call({:select, identifier}, _from, %{status: status} = state)
      when status in [:ready, :active] do
    case do_select(identifier, state) do
      {:ok, _session_id, new_state} ->
        broadcast_session_changed(new_state.slot_index, identifier)
        {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:select, _identifier}, _from, state) do
    {:reply, {:error, {:slot_not_ready, state.status}}, state}
  end

  def handle_call(:deselect, _from, %{status: :active} = state) do
    new_state = %{
      state
      | status: :ready,
        active_identifier: nil,
        active_session_id: nil,
        poll_ref: cancel_poll(state.poll_ref)
    }

    broadcast_session_changed(state.slot_index, nil)

    Logger.info(
      "opencode_slot phase=deselect elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index}"
    )

    {:reply, :ok, new_state}
  end

  def handle_call(:deselect, _from, state), do: {:reply, :ok, state}

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       slot_index: state.slot_index,
       status: state.status,
       active_identifier: state.active_identifier,
       active_session_id: state.active_session_id,
       pane_id: state.pane_id,
       base_url: state.base_url,
       generation: state.generation
     }, state}
  end

  @impl true
  def handle_info(:poll_session, %{status: :active} = state) do
    # U10 will probe a real opencode endpoint here and compare against
    # `state.active_session_id`. Until then this is a no-op tick that
    # keeps the timer alive — Aiur-initiated changes are broadcast
    # directly from `do_select/2`, so the user-facing R3.2 behavior
    # already works for the common case.
    {:noreply, schedule_poll(state)}
  end

  def handle_info(:poll_session, state) do
    # Status changed (e.g. deselect raced with a queued tick) — drop
    # the timer.
    {:noreply, %{state | poll_ref: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %{server_pid: pid} = state) do
    Logger.warning(
      "opencode_slot phase=serve_exit elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(reason)}"
    )

    {:noreply, %{state | status: :failed, server_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_binary(state.token), do: TokenRegistry.delete(state.token)
    if is_pid(state.server_pid), do: GenServer.stop(state.server_pid)
    :ok
  end

  # --- Internals ------------------------------------------------------------

  defp do_select(identifier, state) do
    case SessionWriterRegistry.ensure(identifier, state.base_url) do
      {:ok, %{session_id: session_id, writer_pid: writer_pid}} ->
        :ok = SessionWriter.await_replay(writer_pid, 10_000)

        case ApiClient.select_session(state.base_url, session_id) do
          :ok ->
            _ = safely_nudge_tui(state.base_url, session_id, identifier)

            Logger.info(
              "opencode_slot phase=select elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id}"
            )

            {:ok, session_id,
             %{
               state
               | status: :active,
                 active_identifier: identifier,
                 active_session_id: session_id
             }}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp safely_nudge_tui(base_url, session_id, identifier) do
    marker = "__aiur_stream__:nudge:#{System.unique_integer([:positive])}"
    payload = %{parts: [Protocol.text_part_data(marker, synthetic: true)]}

    case ApiClient.post_message(base_url, session_id, payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "opencode_slot phase=nudge_failed identifier=#{identifier} session_id=#{session_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp broadcast_session_changed(slot_index, identifier_or_nil) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_session_changed, slot_index, identifier_or_nil}
    )
  end

  defp schedule_poll(%{status: :active} = state) do
    interval = poll_interval_ms()
    ref = Process.send_after(self(), :poll_session, interval)
    %{state | poll_ref: ref}
  end

  defp schedule_poll(state), do: state

  defp cancel_poll(nil), do: nil

  defp cancel_poll(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp hidden_window_target do
    case HiddenWindow.status() do
      :ready ->
        try do
          state = :sys.get_state(HiddenWindow, 1_000)
          {:ok, state.keep_alive_pane_id}
        catch
          _, reason -> {:error, {:hidden_window_state_unavailable, reason}}
        end

      :waiting ->
        {:error, :hidden_window_not_ready}

      :failed ->
        {:error, :hidden_window_failed}

      :disabled ->
        {:error, :hidden_window_disabled}
    end
  end

  defp active_agent_identifiers do
    # Mirror WarmServer's source-of-truth.
    Aiur.Orchestrator.list_active_identifiers()
  rescue
    _ -> []
  end

  defp workspace_path_for(slot_index) do
    base = System.user_home!() || "/tmp"
    Path.join([base, ".local/share/aiur/opencode-slot-#{slot_index}"])
  end

  defp process_name(slot_index), do: :"#{__MODULE__}-#{slot_index}"

  defp poll_interval_ms do
    Application.get_env(:aiur, :slot_poll_interval_ms, @default_poll_interval_ms)
  end
end
