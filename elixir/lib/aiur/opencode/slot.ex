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
      :ready            → idle, accepting Slot.attach/2 + Slot.set_visible/2
      :active           → visible_identifier set, poll loop running

  Each slot tracks an `attached_identifiers` MapSet. Attachment is
  independent of visibility: a slot can have N identifiers attached,
  and at most one of them is the `visible_identifier` shown in the
  slot's attach pane.

  Three public lifecycle calls drive a slot:

    * `attach/2` — pre-warm an identifier's session in this slot's
      serve. Idempotent. Broadcasts `{:slot_attach_added, slot, id}`.
    * `set_visible/2` — display an identifier's session in the slot's
      attach pane. Respawns with `--session <id>` on first call, then
      uses `/tui/select-session` for subsequent swaps. Broadcasts
      `{:slot_visible_changed, slot, id}`.
    * `detach/2` — drop the identifier from `attached_identifiers`.
      Broadcasts `{:slot_attach_removed, slot, id}`.

  `Slot.select/2` is `attach + set_visible`; `Slot.deselect/1` is
  `clear_visible`.

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
  @poll_death_threshold 3

  defstruct slot_index: nil,
            status: :booting,
            workspace_path: nil,
            server_pid: nil,
            base_url: nil,
            token: nil,
            generation: 1,
            pane_id: nil,
            attached_identifiers: MapSet.new(),
            visible_identifier: nil,
            visible_session_id: nil,
            # Consecutive empty/unexpected display-message responses
            # from the pane-death poll. tmux returns empty under
            # transient load; one negative reading is not enough to
            # conclude the pane is gone. Concludes death only after
            # @poll_death_threshold consecutive failures.
            poll_death_count: 0,
            # Mirror visible_identifier / visible_session_id for legacy
            # callers still using select/deselect.
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: nil,
            # Identifiers declared in this slot's `opencode.json` models
            # map. opencode-serve does not hot-reload this file; any
            # identifier outside this set fails with `Model not found`.
            # On miss, attach/select triggers a transparent serve
            # rebuild with the freshest active list.
            known_identifiers: MapSet.new(),
            # `{from, identifier}` queued from a `:set_visible` /
            # `:select` whose identifier wasn't in the serve's models
            # map. Drained after `:rebuild_now` reaches `:ready`.
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
  2. Respawns opencode-attach with `--session <session_id>` so the TUI
     boots straight into the conversation view (opencode 1.15.6's TUI
     does not honor POST /tui/select-session once the welcome screen
     is rendered).
  3. Starts the active-session poll loop
  4. Broadcasts `{:slot_session_changed, slot_index, identifier}` on the
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

  @doc """
  Pre-warm `identifier`'s session in this slot's opencode-serve.

  Idempotent: a second call for the same identifier returns
  `{:ok, session_id}` from cache without re-running replay.

  Drives:

  1. `SessionWriterRegistry.ensure/2` for the identifier (history
     replay against the slot's serve).
  2. Adds the identifier to `attached_identifiers`.
  3. Broadcasts `{:slot_attach_added, slot_index, identifier}` on the
     PubSub `slots_topic/0`.

  Does NOT change which session is visible in the slot's attach pane.
  Use `set_visible/2` to display the session.
  """
  @spec attach(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def attach(server, identifier, timeout \\ 15_000) when is_binary(identifier) do
    GenServer.call(server, {:attach, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Attach a list of identifiers sequentially. Returns the list of
  results in input order.

  Sequential rather than parallel for v1: parallel attaches against a
  single serve can hit SQLite contention even after PR #83's
  transaction batching. Tune to parallel with a Task.Supervisor cap if
  attach fan-out wall-time becomes the bottleneck (see U10's
  measurement report).
  """
  @spec attach_many(GenServer.server(), [String.t()], timeout()) ::
          [{:ok, String.t()} | {:error, term()}]
  def attach_many(server, identifiers, timeout \\ 15_000) when is_list(identifiers) do
    Enum.map(identifiers, fn id -> attach(server, id, timeout) end)
  end

  @doc """
  Display `identifier`'s session in this slot's attach pane.

  Ensures the identifier is attached first (calls `attach/2`
  internally if not yet attached). Then:

    * First visible call OR different identifier than currently
      visible: kills the existing attach pane (if any) and respawns
      with `opencode attach --session <id>`. Required because opencode
      1.15.6's TUI does not honor `POST /tui/select-session` when the
      attach is on the welcome screen.
    * If the slot is already visible-bound to `identifier`: no-op
      returning the existing pane_id.

  Broadcasts `{:slot_visible_changed, slot_index, identifier}` on the
  PubSub `slots_topic/0` (legacy `:slot_session_changed` is also
  broadcast for compatibility).

  Returns `{:ok, pane_id}` so PaneManager can move the pane to visible.
  """
  @spec set_visible(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def set_visible(server, identifier, timeout \\ 15_000) when is_binary(identifier) do
    GenServer.call(server, {:set_visible, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Clear the currently-visible session in this slot's attach pane.

  Returns the slot to a state where `visible_identifier == nil`. The
  attach pane itself is preserved (it will continue showing whatever
  session it last rendered) — the user-visible effect is that
  PaneManager will close the chat pane.

  Broadcasts `{:slot_visible_changed, slot_index, nil}` on the PubSub
  topic so AgentList can drop the 🟢 marker.
  """
  @spec clear_visible(GenServer.server()) :: :ok
  def clear_visible(server) do
    GenServer.call(server, :clear_visible, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Detach `identifier` from this slot.

  Removes the identifier from `attached_identifiers`. If it was the
  visible identifier, also clears visibility. The opencode-serve's
  SQLite session row is not deleted here — that's left to
  `SessionGC.run/1` on the next slot reboot.

  Broadcasts `{:slot_attach_removed, slot_index, identifier}` on the
  PubSub topic. Idempotent: detaching an already-detached identifier
  is a no-op `:ok`.
  """
  @spec detach(GenServer.server(), String.t()) :: :ok
  def detach(server, identifier) when is_binary(identifier) do
    GenServer.call(server, {:detach, identifier}, 5_000)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    slot_index = Keyword.fetch!(opts, :slot_index)
    Process.flag(:trap_exit, true)

    case SlotRegistry.register_self(slot_index) do
      :ok ->
        Logger.info("opencode_slot phase=init elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}")

        state = %__MODULE__{
          slot_index: slot_index,
          status: :booting,
          workspace_path: workspace_path_for(slot_index)
        }

        {:ok, state, {:continue, :start_serve}}

      {:error, :already_registered} ->
        Logger.warning("opencode_slot phase=duplicate elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}")

        :ignore
    end
  end

  @impl true
  def handle_continue(:start_serve, state) do
    serve_span = Aiur.Perf.span_begin(:slot_start_serve, slot: state.slot_index)
    Process.put(:slot_serve_span, serve_span)
    bridge_url = "http://#{Config.bridge_host()}:#{Config.bridge_port()}"

    # Pre-seed the slot's models map with all currently-active agent
    # identifiers from the orchestrator. This eliminates the
    # `identifier_miss` rebuild on first open of every agent —
    # previously every first open paid a ~6 s opencode-serve restart
    # to add the chosen identifier to the map. Pre-seeding moves that
    # cost into background pre-warm where the user never sees it.
    #
    # On rebuild (pending_select set), keep the already-accumulated
    # `state.known_identifiers` so we don't drop previously-attached
    # identifiers in the rebuilt serve.
    agent_ids =
      cond do
        state.pending_select != nil ->
          MapSet.to_list(state.known_identifiers)

        MapSet.size(state.known_identifiers) > 0 ->
          MapSet.to_list(state.known_identifiers)

        true ->
          safely_list_active_identifiers()
      end

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
      Logger.info("opencode_slot phase=serve_ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} base_url=#{base_url}")

      if span = Process.get(:slot_serve_span) do
        Aiur.Perf.span_end(span, slot: state.slot_index, base_url: base_url)
        Process.delete(:slot_serve_span)
      end

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
        Logger.warning("opencode_slot phase=serve_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}")

        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_continue(:spawn_attach, state) do
    # Fast path: when a `pending_select` is queued (identifier_miss rebuild),
    # `do_select` is about to respawn attach WITH `--session` anyway. Skip
    # the throwaway no-session attach spawn here to save 1-2 s per first
    # open per slot. Mark ready with pane_id=nil; do_select will create
    # the bound attach pane.
    if state.pending_select do
      mark_ready_pending_select(state)
    else
      mark_ready_with_attach_pane(state)
    end
  end

  defp mark_ready_pending_select(state) do
    Logger.info("opencode_slot phase=ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} pane_id=nil (pending_select fast-path)")

    Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, state.slot_index})
    Aiur.Perf.event(:slot_ready, slot: state.slot_index)
    maybe_run_session_gc(state)

    ready_state = %{state | status: :ready, pane_id: nil}
    {:noreply, drain_pending_select(ready_state)}
  end

  defp mark_ready_with_attach_pane(state) do
    with {:ok, keep_alive_pane} <- hidden_window_target(),
         :ok <- reflow_hidden_window(keep_alive_pane),
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
      Logger.info("opencode_slot phase=ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} pane_id=#{pane_id}")

      Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, state.slot_index})
      Aiur.Perf.event(:slot_ready, slot: state.slot_index)

      # First slot to reach :ready runs boot-time GC. Recovers from any
      # prior aiur run that crashed before its shutdown could reap
      # sessions (kill -9, BEAM panic, OOM). Lifted from WarmServer.
      maybe_run_session_gc(state)

      ready_state = %{state | status: :ready, pane_id: pane_id}
      {:noreply, drain_pending_select(ready_state)}
    else
      error ->
        Logger.warning("opencode_slot phase=attach_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}")

        {:noreply, %{state | status: :failed}}
    end
  end

  defp maybe_run_session_gc(%{slot_index: 1, base_url: base_url}) do
    Task.start(fn -> SessionGC.run(base_url) end)
    :ok
  end

  defp maybe_run_session_gc(_state), do: :ok

  @impl true
  def handle_call({:select, identifier}, from, %{status: status} = state)
      when status in [:ready, :active] do
    do_set_visible_call(identifier, from, state)
  end

  def handle_call({:select, _identifier}, _from, state) do
    {:reply, {:error, {:slot_not_ready, state.status}}, state}
  end

  def handle_call({:attach, identifier}, _from, %{status: status} = state)
      when status in [:ready, :active] do
    case do_attach(identifier, state) do
      {:ok, session_id, new_state} ->
        broadcast_attach_added(new_state.slot_index, identifier)
        {:reply, {:ok, session_id}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:attach, _identifier}, _from, state) do
    {:reply, {:error, {:slot_not_ready, state.status}}, state}
  end

  def handle_call({:set_visible, identifier}, from, %{status: status} = state)
      when status in [:ready, :active] do
    if state.visible_identifier == identifier and is_binary(state.pane_id) do
      {:reply, {:ok, state.pane_id}, state}
    else
      do_set_visible_call(identifier, from, state)
    end
  end

  def handle_call({:set_visible, _identifier}, _from, state) do
    {:reply, {:error, {:slot_not_ready, state.status}}, state}
  end

  def handle_call(:clear_visible, _from, state) do
    new_state =
      if state.visible_identifier do
        broadcast_visible_changed(state.slot_index, nil)

        %{
          state
          | status: :ready,
            visible_identifier: nil,
            visible_session_id: nil,
            active_identifier: nil,
            active_session_id: nil,
            poll_ref: cancel_poll(state.poll_ref)
        }
      else
        state
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:detach, identifier}, _from, state) do
    if MapSet.member?(state.attached_identifiers, identifier) do
      new_state = %{
        state
        | attached_identifiers: MapSet.delete(state.attached_identifiers, identifier)
      }

      new_state =
        if state.visible_identifier == identifier do
          broadcast_visible_changed(new_state.slot_index, nil)

          %{
            new_state
            | status: :ready,
              visible_identifier: nil,
              visible_session_id: nil,
              active_identifier: nil,
              active_session_id: nil,
              poll_ref: cancel_poll(new_state.poll_ref)
          }
        else
          new_state
        end

      broadcast_attach_removed(state.slot_index, identifier)

      Logger.info("opencode_slot phase=detach slot=#{state.slot_index} identifier=#{identifier}")
      Aiur.Perf.event(:slot_attach_removed, slot: state.slot_index, identifier: identifier)

      {:reply, :ok, new_state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:deselect, _from, %{status: :active} = state) do
    new_state = %{
      state
      | status: :ready,
        active_identifier: nil,
        active_session_id: nil,
        visible_identifier: nil,
        visible_session_id: nil,
        poll_ref: cancel_poll(state.poll_ref)
    }

    broadcast_session_changed(state.slot_index, nil)
    broadcast_visible_changed(state.slot_index, nil)
    Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, state.slot_index})
    Aiur.Perf.event(:slot_ready, slot: state.slot_index)

    Logger.info("opencode_slot phase=deselect elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index}")

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
       visible_identifier: state.visible_identifier,
       visible_session_id: state.visible_session_id,
       attached_identifiers: state.attached_identifiers,
       pane_id: state.pane_id,
       base_url: state.base_url,
       generation: state.generation
     }, state}
  end

  @impl true
  def handle_info(:poll_session, %{status: :active, pane_id: pane_id} = state)
      when is_binary(pane_id) do
    # tmux's `display-message -t <pane>` returns empty under transient
    # load even when the pane is alive (verified against a real run
    # where capture-pane on a freshly-spawned sibling was returning
    # empty in a tight loop). One bad reading is not enough — require
    # @poll_death_threshold consecutive failures before tearing the
    # slot down.
    result = Tmux.command(Tmux, "display-message -p -t #{pane_id} \#{pane_id}")

    case result do
      {:ok, [^pane_id | _]} ->
        {:noreply, schedule_poll(%{state | poll_death_count: 0})}

      other ->
        bumped = state.poll_death_count + 1

        Logger.info(
          "opencode_slot phase=poll_pane_missing slot=#{state.slot_index} pane_id=#{pane_id} attempt=#{bumped}/#{@poll_death_threshold} poll_result=#{inspect(other)}"
        )

        if bumped >= @poll_death_threshold do
          capture_dump =
            case Tmux.command(Tmux, "capture-pane -p -t #{pane_id}") do
              {:ok, lines} ->
                lines |> Enum.take(8) |> Enum.join(" \\ ")

              _ ->
                "capture_failed"
            end

          Logger.warning(
            "opencode_slot phase=pane_died elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{state.active_identifier} pane_id=#{pane_id} consecutive_failures=#{bumped} capture_at_death=#{inspect(capture_dump)}"
          )

          Aiur.Perf.event(:slot_poll_pane_died,
            slot: state.slot_index,
            identifier: state.active_identifier,
            pane_id: pane_id,
            consecutive_failures: bumped,
            capture_at_death: capture_dump
          )

          broadcast_session_changed(state.slot_index, nil)
          broadcast_visible_changed(state.slot_index, nil)

          new_state = %{
            state
            | status: :attach_spawning,
              pane_id: nil,
              active_identifier: nil,
              active_session_id: nil,
              visible_identifier: nil,
              visible_session_id: nil,
              poll_ref: nil,
              poll_death_count: 0
          }

          {:noreply, new_state, {:continue, :spawn_attach}}
        else
          {:noreply, schedule_poll(%{state | poll_death_count: bumped})}
        end
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
    Logger.warning("opencode_slot phase=serve_exit elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(reason)}")

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

  defp do_attach(identifier, state) do
    cond do
      MapSet.member?(state.attached_identifiers, identifier) ->
        sid =
          if state.visible_identifier == identifier do
            state.visible_session_id
          else
            :attached
          end

        {:ok, sid, state}

      identifier_known?(state, identifier) ->
        do_attach_known(identifier, state)

      true ->
        {:error, :identifier_unknown}
    end
  end

  defp do_attach_known(identifier, state) do
    span =
      Aiur.Perf.span_begin(:slot_do_attach,
        slot: state.slot_index,
        identifier: identifier
      )

    case ensure_session_for(identifier, state) do
      {:ok, session_id} ->
        Aiur.Perf.span_end(span,
          slot: state.slot_index,
          identifier: identifier,
          session_id: session_id
        )

        new_state = %{
          state
          | attached_identifiers: MapSet.put(state.attached_identifiers, identifier)
        }

        new_state = maybe_render_leadoff_pane(identifier, session_id, new_state)

        Aiur.Perf.event(:slot_attach_added,
          slot: state.slot_index,
          identifier: identifier,
          session_id: session_id
        )

        Logger.info(
          "opencode_slot phase=attach slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id}"
        )

        {:ok, session_id, new_state}

      {:error, reason} = err ->
        Aiur.Perf.span_end(span,
          result: :failed,
          slot: state.slot_index,
          identifier: identifier,
          reason: reason
        )

        err
    end
  end

  # Pre-render the slot's attach pane bound to the first attached
  # identifier. Boot leaves the pane on opencode's welcome screen with
  # no session; we kill that pane and respawn with `--session <id>` so
  # the pane sits in aiur-hidden fully painted. PaneManager moves it
  # visible on user open — without this, the ⚪ marker lies because
  # the open path still pays the 5-7s pane-spawn cost.
  defp maybe_render_leadoff_pane(identifier, session_id, state) do
    if is_nil(state.visible_identifier) do
      Logger.info(
        "opencode_slot phase=leadoff_render_start slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id}"
      )

      span =
        Aiur.Perf.span_begin(:slot_leadoff_render,
          slot: state.slot_index,
          identifier: identifier
        )

      case respawn_attach_with_session(state, session_id) do
        {:ok, new_pane_id} ->
          paint_result = Aiur.Opencode.AttachPool.wait_for_paint(new_pane_id, 20_000)

          Aiur.Perf.span_end(span,
            slot: state.slot_index,
            identifier: identifier,
            pane_id: new_pane_id,
            paint: paint_result
          )

          Logger.info(
            "opencode_slot phase=leadoff_render_done slot=#{state.slot_index} identifier=#{identifier} pane_id=#{new_pane_id} paint=#{paint_result}"
          )

          %{
            state
            | pane_id: new_pane_id,
              visible_identifier: identifier,
              visible_session_id: session_id,
              active_identifier: identifier,
              active_session_id: session_id
          }

        {:error, reason} ->
          Aiur.Perf.span_end(span,
            result: :failed,
            slot: state.slot_index,
            identifier: identifier,
            reason: reason
          )

          state
      end
    else
      state
    end
  end

  defp ensure_session_for(identifier, state) do
    case SessionWriterRegistry.ensure(identifier, state.base_url) do
      {:ok, %{session_id: session_id, writer_pid: writer_pid}} ->
        case SessionWriter.await_replay(writer_pid, 10_000) do
          :ok -> {:ok, session_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_set_visible_call(identifier, from, state) do
    cond do
      not identifier_known?(state, identifier) ->
        Logger.info(
          "opencode_slot phase=identifier_miss elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier}"
        )

        Aiur.Perf.event(:slot_identifier_miss,
          slot: state.slot_index,
          identifier: identifier
        )

        pending = {from, identifier}
        {:noreply, schedule_serve_rebuild(state, pending)}

      can_select_via_api?(state, identifier) ->
        do_select_via_api(identifier, state)

      true ->
        case do_select(identifier, state) do
          {:ok, _session_id, new_state} ->
            broadcast_session_changed(new_state.slot_index, identifier)
            broadcast_visible_changed(new_state.slot_index, identifier)
            {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  # The pane is already painted on a real conversation and we want to
  # swap to a different attached identifier. `/tui/select-session`
  # updates the pane's rendered conversation in-place (verified by the
  # #85 spike against opencode 1.15.6), avoiding the 5-7s kill+respawn.
  defp can_select_via_api?(state, identifier) do
    is_binary(state.pane_id) and
      not is_nil(state.visible_identifier) and
      state.visible_identifier != identifier and
      MapSet.member?(state.attached_identifiers, identifier)
  end

  defp do_select_via_api(identifier, state) do
    span =
      Aiur.Perf.span_begin(:slot_select_via_api,
        slot: state.slot_index,
        identifier: identifier
      )

    case SessionWriterRegistry.ensure(identifier, state.base_url) do
      {:ok, %{session_id: session_id}} ->
        case Aiur.Opencode.ApiClient.select_session(state.base_url, session_id) do
          :ok ->
            Aiur.Perf.span_end(span,
              slot: state.slot_index,
              identifier: identifier,
              session_id: session_id
            )

            Logger.info(
              "opencode_slot phase=select_via_api slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id} pane_id=#{state.pane_id}"
            )

            new_state = %{
              state
              | status: :active,
                visible_identifier: identifier,
                visible_session_id: session_id,
                active_identifier: identifier,
                active_session_id: session_id
            }

            broadcast_session_changed(new_state.slot_index, identifier)
            broadcast_visible_changed(new_state.slot_index, identifier)
            {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

          {:error, reason} ->
            Aiur.Perf.span_end(span,
              result: :api_failed,
              slot: state.slot_index,
              identifier: identifier,
              reason: reason
            )

            # Fall back to the kill+respawn path when the API call
            # fails so the user still gets the session swap, just
            # paying the slower cost.
            case do_select(identifier, state) do
              {:ok, _session_id, new_state} ->
                broadcast_session_changed(new_state.slot_index, identifier)
                broadcast_visible_changed(new_state.slot_index, identifier)
                {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

              {:error, _} = err ->
                {:reply, err, state}
            end
        end

      {:error, reason} = err ->
        Aiur.Perf.span_end(span,
          result: :ensure_failed,
          slot: state.slot_index,
          identifier: identifier,
          reason: reason
        )

        {:reply, err, state}
    end
  end

  defp do_select(identifier, state) do
    do_select_span =
      Aiur.Perf.span_begin(:slot_do_select,
        slot: state.slot_index,
        identifier: identifier
      )

    case SessionWriterRegistry.ensure(identifier, state.base_url) do
      {:ok, %{session_id: session_id, writer_pid: writer_pid}} ->
        replay_span =
          Aiur.Perf.span_begin(:session_writer_await_replay,
            slot: state.slot_index,
            identifier: identifier,
            session_id: session_id
          )

        case SessionWriter.await_replay(writer_pid, 10_000) do
          :ok ->
            Aiur.Perf.span_end(replay_span,
              slot: state.slot_index,
              identifier: identifier,
              session_id: session_id
            )

            select_with_respawn(state, identifier, session_id, do_select_span)

          {:error, reason} = err ->
            # Replay timed out or the writer disappeared. Surface as a
            # plain Slot.select error so AttachPool's warm Task can call
            # broadcast_event({:attach_failed, ...}) instead of the slot
            # crashing with MatchError and taking the warm Task with it
            # (which is what wedged 4 of 5 agents in ⏳ on 2026-05-22).
            Aiur.Perf.span_end(replay_span,
              result: :failed,
              slot: state.slot_index,
              identifier: identifier,
              session_id: session_id,
              reason: reason
            )

            Aiur.Perf.span_end(do_select_span,
              result: :replay_failed,
              slot: state.slot_index,
              identifier: identifier,
              reason: reason
            )

            err
        end

      {:error, _} = err ->
        Aiur.Perf.span_end(do_select_span,
          result: :writer_failed,
          slot: state.slot_index,
          identifier: identifier
        )

        err
    end
  end

  # Respawn opencode-attach with `--session <id>` so the TUI boots
  # straight into the conversation view. POSTing
  # `/tui/select-session` to an already-running pre-warmed attach
  # returns 200 but does not switch the rendered view — opencode
  # 1.15.6's TUI stays on the welcome screen ("Ask anything...",
  # OPENCODE logo). The previously-pre-warmed attach pane is killed
  # and a new one is split into aiur-hidden so PaneManager can
  # move it to visible. State.pane_id is updated to the new pane.
  defp select_with_respawn(state, identifier, session_id, do_select_span) do
    case respawn_attach_with_session(state, session_id) do
      {:ok, new_pane_id} ->
        Logger.info("opencode_slot phase=select elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id} pane_id=#{new_pane_id}")

        Aiur.Perf.span_end(do_select_span,
          slot: state.slot_index,
          identifier: identifier,
          session_id: session_id,
          pane_id: new_pane_id
        )

        {:ok, session_id,
         %{
           state
           | status: :active,
             active_identifier: identifier,
             active_session_id: session_id,
             visible_identifier: identifier,
             visible_session_id: session_id,
             attached_identifiers: MapSet.put(state.attached_identifiers, identifier),
             pane_id: new_pane_id
         }}

      {:error, _} = err ->
        Aiur.Perf.span_end(do_select_span,
          result: :respawn_failed,
          slot: state.slot_index,
          identifier: identifier
        )

        err
    end
  end

  # Kill the slot's existing opencode-attach pane (the pre-warmed
  # session-less one, or any previous session's attach) and spawn a
  # fresh attach bound to `session_id`. Returns the new pane id.
  defp respawn_attach_with_session(state, session_id) do
    span =
      Aiur.Perf.span_begin(:slot_respawn_attach,
        slot: state.slot_index,
        session_id: session_id
      )

    if is_binary(state.pane_id) do
      Logger.warning(
        "opencode_slot phase=kill_for_respawn slot=#{state.slot_index} old_pane_id=#{state.pane_id} session_id=#{session_id}"
      )

      _ = Tmux.command(Tmux, "kill-pane -t #{state.pane_id}")
    end

    with {:ok, keep_alive_pane} <- hidden_window_target(),
         :ok <- reflow_hidden_window(keep_alive_pane),
         attach_cmd = Protocol.attach_command(state.base_url, session_id),
         {:ok, pane_id} <-
           Tmux.split_pane(
             Tmux,
             keep_alive_pane,
             :horizontal,
             @hidden_split_percent,
             attach_cmd,
             silent: true
           ) do
      Aiur.Perf.span_end(span,
        slot: state.slot_index,
        session_id: session_id,
        pane_id: pane_id
      )

      {:ok, pane_id}
    else
      error ->
        Logger.warning("opencode_slot phase=respawn_attach_failed slot=#{state.slot_index} session_id=#{session_id} reason=#{inspect(error)}")

        Aiur.Perf.span_end(span,
          result: :failed,
          slot: state.slot_index,
          session_id: session_id
        )

        {:error, :respawn_failed}
    end
  end

  # Redistribute pane widths across the hidden window so the keep-alive
  # sentinel pane never shrinks below tmux's minimum splittable width.
  # Without this, repeated kill+split cycles (one per identifier_miss
  # rebuild + one per session-bound respawn) halve the sentinel pane
  # each time; after enough cycles tmux returns `no space for new pane`
  # and the slot gets stuck.
  defp reflow_hidden_window(keep_alive_pane) do
    # `even-horizontal` requires at least 2 panes; tolerate a 1-pane
    # window (would be just the sentinel) by ignoring layout errors.
    case Tmux.command(Tmux, "select-layout -t #{keep_alive_pane} even-horizontal") do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp identifier_known?(%{known_identifiers: known}, identifier) do
    MapSet.member?(known, identifier)
  end

  # Pull the orchestrator's currently-active identifier list. The
  # orchestrator starts agents asynchronously after the slot supervisor
  # starts, so the list may be empty when the first slot boots. Poll
  # briefly (up to ~3 s) waiting for at least one agent so the
  # pre-warmed serve includes a useful models map and the first open
  # hits the warm path. If still empty after the budget, proceed with
  # an empty map — first open will pay the identifier_miss rebuild.
  @orchestrator_wait_budget_ms 3_000
  @orchestrator_poll_interval_ms 100

  defp safely_list_active_identifiers do
    do_wait_for_active_identifiers(0)
  end

  defp do_wait_for_active_identifiers(waited_ms) when waited_ms >= @orchestrator_wait_budget_ms do
    fetch_active_identifiers()
  end

  defp do_wait_for_active_identifiers(waited_ms) do
    case fetch_active_identifiers() do
      [] ->
        Process.sleep(@orchestrator_poll_interval_ms)
        do_wait_for_active_identifiers(waited_ms + @orchestrator_poll_interval_ms)

      ids ->
        ids
    end
  end

  defp fetch_active_identifiers do
    Aiur.Orchestrator.list_active_identifiers(Aiur.Orchestrator, 500)
  rescue
    _ -> []
  catch
    _, _ -> []
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

  defp broadcast_attach_added(slot_index, identifier) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_attach_added, slot_index, identifier}
    )
  end

  defp broadcast_attach_removed(slot_index, identifier) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_attach_removed, slot_index, identifier}
    )
  end

  defp broadcast_visible_changed(slot_index, identifier_or_nil) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @slots_topic,
      {:slot_visible_changed, slot_index, identifier_or_nil}
    )
  end

  defp schedule_poll(%{status: :active} = state) do
    # Cancel any prior pending poll timer before scheduling a new one.
    # Otherwise rapid back-to-back swaps stack multiple Process.send_after
    # timers; they all fire 500ms later within milliseconds of each
    # other, defeating the consecutive-failures debounce and false-
    # tearing the slot down.
    _ = cancel_poll(state.poll_ref)
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
    base = System.user_home!()
    Path.join([base, ".local/share/aiur/opencode-slot-#{slot_index}"])
  end

  defp process_name(slot_index), do: :"#{__MODULE__}-#{slot_index}"

  defp poll_interval_ms do
    Application.get_env(:aiur, :slot_poll_interval_ms, @default_poll_interval_ms)
  end
end
