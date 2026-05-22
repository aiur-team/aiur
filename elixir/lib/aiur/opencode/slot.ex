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
            poll_ref: nil,
            # Identifiers declared in this slot's `opencode.json` models
            # map at the time `materialize_slot/5` ran. opencode-serve
            # does not hot-reload this file; any identifier NOT in this
            # set will fail with `Model not found: aiur/issue-X. Did you
            # mean: issue-Y, ...` from the bridge. When `Slot.select/2`
            # sees a miss it triggers a transparent serve restart with
            # the freshest `list_active_identifiers/0` before proceeding.
            known_identifiers: MapSet.new(),
            pending_select: nil

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

    # Slot's models map grows incrementally — boot with whatever's in
    # `state.known_identifiers` (empty on first boot; carries previous
    # entries on serve rebuild for identifier_miss). No wait for
    # `Aiur.Orchestrator.list_active_identifiers/0` — slots are useful
    # without knowing about any agent, and grow on demand when
    # `Slot.select/2` is called with a missing identifier (U3 rebuild).
    agent_ids = MapSet.to_list(state.known_identifiers)

    # On rebuild, set the slot's top-level `model` field (which drives
    # opencode-attach's status bar) to the identifier that triggered
    # the rebuild — so the user sees `Build · issue-10` instead of the
    # slot sentinel. On initial boot (pending_select is nil), let
    # materialize_slot fall back to the sentinel.
    display_opt =
      case state.pending_select do
        {_from, identifier} -> [display_identifier: identifier]
        _ -> []
      end

    with :ok <- File.mkdir_p(state.workspace_path),
         {:ok, token} <-
           WorkspaceSetup.materialize_slot(
             state.workspace_path,
             bridge_url,
             agent_ids,
             state.slot_index,
             state.generation,
             display_opt
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
          token: token,
          known_identifiers: MapSet.new(agent_ids)
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

      ready_state = %{state | status: :ready, pane_id: pane_id}
      {:noreply, drain_pending_select(ready_state)}
    else
      error ->
        Logger.warning(
          "opencode_slot phase=attach_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}"
        )

        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call({:select, identifier}, from, %{status: status} = state)
      when status in [:ready, :active] do
    if identifier_known?(state, identifier) do
      case do_select(identifier, state) do
        {:ok, _session_id, new_state} ->
          broadcast_session_changed(new_state.slot_index, identifier)
          {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

        {:error, _} = err ->
          {:reply, err, state}
      end
    else
      # opencode-serve doesn't hot-reload opencode.json, so an identifier
      # that wasn't active when this slot booted will fail with
      # `Model not found`. Rebuild the slot's serve transparently with
      # the freshest agent list, THEN retry the select. The user pays
      # a one-time ~5s pause on this open; subsequent opens of any
      # identifier known to the new map are warm.
      Logger.info(
        "opencode_slot phase=identifier_miss elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier}"
      )

      pending = {from, identifier}
      {:noreply, schedule_serve_rebuild(state, pending)}
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
  def handle_info(:poll_session, %{status: :active, pane_id: pane_id} = state)
      when is_binary(pane_id) do
    # Detect external pane death (user pressed Ctrl+C inside opencode,
    # opencode-attach exited, tmux destroyed the pane). `Aiur.Tmux`
    # exposes no live event stream, so we poll. tmux's `display-message
    # -t <dead-pane>` silently routes to the active pane and returns
    # the OTHER pane's id, or an empty list — exit 0 either way. We
    # must compare the returned id against our recorded pane_id.
    result = Tmux.command(Tmux, "display-message -p -t #{pane_id} \#{pane_id}")

    case result do
      {:ok, [^pane_id | _]} ->
        {:noreply, schedule_poll(state)}

      _ ->
        Logger.info(
          "opencode_slot phase=pane_died elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{state.active_identifier} pane_id=#{pane_id}"
        )

        # AgentList must drop the circle immediately — no `Slot.deselect`
        # call from PaneManager since the pane vanished without going
        # through `close_conversation`.
        broadcast_session_changed(state.slot_index, nil)

        # opencode-serve is still alive; respawn just the attach pane
        # (cheap, ~50ms) so the slot is reusable for the next open.
        new_state = %{
          state
          | status: :attach_spawning,
            pane_id: nil,
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: nil
        }

        {:noreply, new_state, {:continue, :spawn_attach}}
    end
  end

  def handle_info(:poll_session, state) do
    # Status changed (e.g. deselect raced with a queued tick) — drop
    # the timer.
    {:noreply, %{state | poll_ref: nil}}
  end

  def handle_info(:rebuild_now, state) do
    # Triggered by `schedule_serve_rebuild/2` to re-enter the boot path.
    # State has already been reset; just kick the start_serve continuation.
    {:noreply, state, {:continue, :start_serve}}
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

        case select_session_with_retry(state.base_url, session_id, 5) do
          :ok ->
            # No synthetic nudge here. The old AgentAttach path POSTed a
            # `__aiur_stream__:nudge:<N>` user turn to force the TUI to
            # refresh after history-replay; the bridge used to 400 that
            # request (visible as a toast). With the bridge now accepting
            # nudge markers as empty SSE streams, opencode COMMITS the
            # nudge as a user turn with no assistant reply and jumps the
            # view to that empty turn — masking the actual history we
            # just replayed. `/tui/select-session` alone is sufficient:
            # opencode loads SQLite-resident rows for the selected
            # session id on its own.

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

  # `POST /tui/select-session` only succeeds when opencode-attach has
  # completed its WebSocket handshake with the serve. Immediately after
  # a slot rebuild the attach is spawning but may not be connected yet,
  # so retry with a brief backoff (capped at ~1.5s total).
  defp select_session_with_retry(_base_url, _session_id, 0), do: {:error, :tui_not_ready}

  defp select_session_with_retry(base_url, session_id, attempts) do
    case ApiClient.select_session(base_url, session_id) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(300)
        select_session_with_retry(base_url, session_id, attempts - 1)
    end
  end

  defp identifier_known?(%{known_identifiers: known}, identifier) do
    MapSet.member?(known, identifier)
  end

  # Called on transition to `:ready`. If a `:select` GenServer call was
  # deferred because the identifier wasn't in this slot's models map,
  # complete it now: run `do_select`, broadcast the visibility event,
  # and reply to the original caller. Returns the new state.
  defp drain_pending_select(%{pending_select: nil} = state), do: state

  defp drain_pending_select(%{pending_select: {from, identifier}} = state) do
    case do_select(identifier, state) do
      {:ok, _session_id, new_state} ->
        broadcast_session_changed(new_state.slot_index, identifier)
        GenServer.reply(from, {:ok, new_state.pane_id})
        schedule_poll(%{new_state | pending_select: nil})

      {:error, _} = err ->
        GenServer.reply(from, err)
        %{state | pending_select: nil}
    end
  end

  # Rebuild the slot's opencode-serve + workspace + attach pane so the
  # new models map includes a previously-unknown identifier. Stores
  # `{from, identifier}` in `pending_select`; once the rebuild reaches
  # `:ready` again, `handle_continue(:spawn_attach, ...)` drains it.
  defp schedule_serve_rebuild(state, {_from, identifier} = pending) do
    # Tear down the existing serve + pane. Bump generation + delete
    # the old token so the bridge can't accept stale auth from a
    # still-running opencode process after we replace it.
    if is_pid(state.server_pid) and Process.alive?(state.server_pid) do
      _ = GenServer.stop(state.server_pid, :normal, 1_000)
    end

    # Kill the old attach pane NOW (before we clear state.pane_id below)
    # so the hidden window's pane budget stays bounded across rebuilds.
    # Without this, every identifier_miss leaks a tmux pane; once the
    # window hits its 6-pane cap the next `split_pane` fails with
    # `no space for new pane` and the rebuild silently aborts.
    if is_binary(state.pane_id) do
      _ = Tmux.command(Tmux, "kill-pane -t #{state.pane_id}")
    end

    if is_binary(state.token), do: TokenRegistry.delete(state.token)

    # Kick the rebuild via a self-message so we can return :noreply now
    # and the next mailbox dispatch re-enters via :rebuild_now → start_serve.
    send(self(), :rebuild_now)

    # Add JUST the missing identifier to the known set — incremental,
    # not "every active agent in the orchestrator". Previously-attached
    # identifiers stay in the set so future selects for them hit the
    # warm path. This is what makes R4 (manual attach in same pane)
    # work cheaply after the first attach.
    next_known = MapSet.put(state.known_identifiers, identifier)

    %{
      state
      | status: :booting,
        server_pid: nil,
        base_url: nil,
        token: nil,
        pane_id: nil,
        generation: state.generation + 1,
        known_identifiers: next_known,
        pending_select: pending,
        active_identifier: nil,
        active_session_id: nil,
        poll_ref: cancel_poll(state.poll_ref)
    }
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

  defp workspace_path_for(slot_index) do
    base = System.user_home!() || "/tmp"
    Path.join([base, ".local/share/aiur/opencode-slot-#{slot_index}"])
  end

  defp process_name(slot_index), do: :"#{__MODULE__}-#{slot_index}"

  defp poll_interval_ms do
    Application.get_env(:aiur, :slot_poll_interval_ms, @default_poll_interval_ms)
  end
end
