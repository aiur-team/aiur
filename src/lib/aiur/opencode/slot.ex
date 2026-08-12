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
                        → broadcast {:slot_ready, slot_index, pid} on "opencode:slots"
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
      attach pane. Always respawns opencode-attach with `--session <id>`.
      The `/tui/select-session` HTTP path was removed: opencode 1.15.6
      returns 200 to it but then exits the attach process seconds later,
      killing the user's pane. Broadcasts
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
  The Slot bumps `generation` each restart. Tokens are registered against
  `{slot_index, generation}` and deleted only after the new attach is ready
  — preventing empty registry windows mid-restart.
  """

  use GenServer
  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{Protocol, SlotRegistry}
  alias Aiur.Opencode.Slot.{AttachPane, Events, ServeLifecycle, Sessions, State}

  @default_poll_interval_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    slot_index = Keyword.fetch!(opts, :slot_index)
    GenServer.start_link(__MODULE__, opts, name: process_name(slot_index))
  end

  @doc "PubSub topic for slot lifecycle events."
  @spec slots_topic() :: String.t()
  defdelegate slots_topic, to: Events

  @doc "Select an agent's session in this slot (attach + set_visible + poll start)."
  @spec select(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def select(server, identifier, timeout \\ 15_000) when is_binary(identifier) do
    GenServer.call(server, {:select, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Release the active identifier; slot returns to `:ready`."
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

  @doc "Atomically reserve an idle slot for termination."
  @spec reserve_stop(GenServer.server()) :: :ok | :busy
  def reserve_stop(server) do
    GenServer.call(server, :reserve_stop, 2_000)
  catch
    :exit, _ -> :busy
  end

  @doc "Atomically claim an idle slot for a caller about to select it."
  @spec claim_ready(GenServer.server()) :: :ok | :busy
  def claim_ready(server) do
    GenServer.call(server, :claim_ready, 2_000)
  catch
    :exit, _ -> :busy
  end

  @doc "Pre-warm `identifier`'s session. Idempotent. Does not change visibility."
  @spec attach(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def attach(server, identifier, timeout \\ 15_000) when is_binary(identifier) do
    GenServer.call(server, {:attach, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Attach a list of identifiers sequentially. Sequential rather than parallel
  for v1: parallel attaches hit SQLite contention even after PR #83's batching.
  """
  @spec attach_many(GenServer.server(), [String.t()], timeout()) ::
          [{:ok, String.t()} | {:error, term()}]
  def attach_many(server, identifiers, timeout \\ 15_000) when is_list(identifiers) do
    Enum.map(identifiers, fn id -> attach(server, id, timeout) end)
  end

  @doc "Display `identifier`'s session in the slot's attach pane. Respawns opencode-attach."
  @spec set_visible(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def set_visible(server, identifier, timeout \\ 15_000) when is_binary(identifier) do
    GenServer.call(server, {:set_visible, identifier}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_slot}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Clear the currently-visible session; slot returns to `visible_identifier == nil`."
  @spec clear_visible(GenServer.server()) :: :ok
  def clear_visible(server) do
    GenServer.call(server, :clear_visible, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Detach `identifier`. Idempotent. Broadcasts `:slot_attach_removed`."
  @spec detach(GenServer.server(), String.t()) :: :ok
  def detach(server, identifier) when is_binary(identifier) do
    GenServer.call(server, {:detach, identifier}, 5_000)
  catch
    :exit, _ -> :ok
  end

  @spec terminate_pane_command(map()) :: String.t() | nil
  defdelegate terminate_pane_command(state), to: AttachPane

  @spec writers_for_base_url([map()], String.t()) :: [map()]
  defdelegate writers_for_base_url(entries, base_url), to: ServeLifecycle

  @impl true
  def init(opts) do
    slot_index = Keyword.fetch!(opts, :slot_index)
    Process.flag(:trap_exit, true)

    case SlotRegistry.register_self(slot_index) do
      :ok ->
        Logger.info("opencode_slot phase=init elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}")
        workspace = ServeLifecycle.workspace_path_for(slot_index)
        state = %State{slot_index: slot_index, status: :booting, workspace_path: workspace}
        {:ok, state, {:continue, :start_serve}}

      {:error, :already_registered} ->
        Logger.warning("opencode_slot phase=duplicate elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index}")
        :ignore
    end
  end

  @impl true
  def handle_continue(:start_serve, state) do
    agent_ids =
      case State.rebuild_seed_identifiers(state) do
        {:known, ids} -> ids
        :poll_orchestrator -> ServeLifecycle.safely_list_active_identifiers()
      end

    display_opt = State.display_opt(state)

    case ServeLifecycle.boot(state, agent_ids, display_opt) do
      {:ok, server_pid, base_url, token} ->
        {:noreply, State.serve_ready(state, server_pid, base_url, token, agent_ids), {:continue, :spawn_attach}}

      {:error, _} ->
        {:noreply, %{state | status: :failed}}
    end
  end

  def handle_continue(:spawn_attach, state) do
    if state.pending_select, do: mark_ready_pending_select(state), else: mark_ready_with_attach_pane(state)
  end

  defp mark_ready_pending_select(state) do
    Logger.info("opencode_slot phase=ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} pane_id=nil (pending_select fast-path)")
    Events.slot_ready(state.slot_index, self())
    ServeLifecycle.maybe_run_session_gc(state)
    ready_state = State.attach_pane_ready(state, nil)
    {:noreply, ready_state |> drain_pending_select() |> drain_pending_attaches()}
  end

  defp mark_ready_with_attach_pane(state) do
    with {:ok, keep_alive_pane} <- AttachPane.hidden_window_target(),
         :ok <- AttachPane.reflow_hidden_window(keep_alive_pane),
         {:ok, pane_id} <- AttachPane.spawn(state.slot_index, state.base_url, keep_alive_pane) do
      Logger.info("opencode_slot phase=ready elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} pane_id=#{pane_id}")
      Events.slot_ready(state.slot_index, self())
      AttachPane.maybe_start_pipe_pane(state.slot_index, pane_id)
      # First slot to reach :ready runs boot-time GC. Recovers from any
      # prior aiur run that crashed before its shutdown could reap
      # sessions (kill -9, BEAM panic, OOM). Lifted from WarmServer.
      ServeLifecycle.maybe_run_session_gc(state)
      ready_state = State.attach_pane_ready(state, pane_id)
      {:noreply, ready_state |> drain_pending_select() |> drain_pending_attaches()}
    else
      error ->
        Logger.warning("opencode_slot phase=attach_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(error)}")
        {:noreply, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_call({:select, identifier}, from, %{status: status} = state)
      when status in [:ready, :claimed, :active],
      do: do_set_visible_call(identifier, from, state)

  def handle_call({:select, _identifier}, _from, state),
    do: {:reply, {:error, {:slot_not_ready, state.status}}, state}

  def handle_call(:reserve_stop, _from, %{status: :ready} = state),
    do: {:reply, :ok, %{state | status: :stopping}}

  def handle_call(:reserve_stop, _from, state), do: {:reply, :busy, state}

  def handle_call(:claim_ready, _from, %{status: :ready} = state),
    do: {:reply, :ok, %{state | status: :claimed}}

  def handle_call(:claim_ready, _from, state), do: {:reply, :busy, state}

  def handle_call({:attach, identifier}, _from, %{status: status} = state)
      when status in [:ready, :claimed, :active] do
    case do_attach(identifier, state) do
      {:ok, session_id, new_state} ->
        Events.attach_added(new_state.slot_index, identifier)
        {:reply, {:ok, session_id}, new_state}

      {:error, :identifier_unknown} ->
        # Agent became active post-boot and isn't in this serve's
        # models map. Reply now (callers — background fill — won't
        # block) and schedule a serve rebuild to incorporate the
        # identifier. The rebuild's :ready continuation drains
        # `pending_attaches` and re-fires the attach so the next
        # consume can warm-open this identifier from this slot.
        new_state = State.queue_pending_attach(state, identifier)
        Aiur.Perf.event(:slot_attach_rebuild_scheduled, slot: state.slot_index, identifier: identifier)
        {:reply, {:error, :identifier_unknown}, schedule_serve_rebuild(new_state, state.pending_select)}

      {:error, _} = err ->
        {:reply, err, unclaim(state)}
    end
  end

  def handle_call({:attach, _identifier}, _from, state),
    do: {:reply, {:error, {:slot_not_ready, state.status}}, state}

  def handle_call({:set_visible, identifier}, from, %{status: status} = state)
      when status in [:ready, :claimed, :active] do
    if state.visible_identifier == identifier and is_binary(state.pane_id) do
      {:reply, {:ok, state.pane_id}, state}
    else
      do_set_visible_call(identifier, from, state)
    end
  end

  def handle_call({:set_visible, _identifier}, _from, state),
    do: {:reply, {:error, {:slot_not_ready, state.status}}, state}

  def handle_call(:clear_visible, _from, state) do
    new_state =
      if state.visible_identifier do
        Events.visible_changed(state.slot_index, nil, state.pane_id)
        _ = cancel_poll(state.poll_ref)
        State.clear_visible(state)
      else
        state
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:detach, identifier}, _from, state) do
    case State.detach(state, identifier) do
      :not_attached ->
        {:reply, :ok, state}

      {clears_visible?, new_state} ->
        if clears_visible? do
          Events.visible_changed(new_state.slot_index, nil, new_state.pane_id)
          _ = cancel_poll(state.poll_ref)
        end

        Events.attach_removed(state.slot_index, identifier)
        Logger.info("opencode_slot phase=detach slot=#{state.slot_index} identifier=#{identifier}")
        Aiur.Perf.event(:slot_attach_removed, slot: state.slot_index, identifier: identifier)
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:deselect, _from, %{status: :active} = state) do
    _ = cancel_poll(state.poll_ref)
    new_state = State.deselect(state)
    Events.session_changed(state.slot_index, nil)
    Events.visible_changed(state.slot_index, nil, state.pane_id)
    Events.slot_ready(state.slot_index, self())
    Logger.info("opencode_slot phase=deselect elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index}")
    {:reply, :ok, new_state}
  end

  def handle_call(:deselect, _from, state), do: {:reply, :ok, state}

  def handle_call(:snapshot, _from, state),
    do: {:reply, State.snapshot(state), state}

  @impl true
  def handle_info(:poll_session, %{status: :active, pane_id: pane_id} = state)
      when is_binary(pane_id) do
    case State.record_poll(state, AttachPane.probe(pane_id)) do
      {:alive, new_state} ->
        {:noreply, schedule_poll(new_state)}

      {:retry, bumped, raw, new_state} ->
        Logger.info("opencode_slot phase=poll_pane_missing slot=#{state.slot_index} pane_id=#{pane_id} attempt=#{bumped}/#{State.poll_death_threshold()} poll_result=#{inspect(raw)}")
        {:noreply, schedule_poll(new_state)}

      {:dead, bumped, raw, _dead_state} ->
        Logger.info("opencode_slot phase=poll_pane_missing slot=#{state.slot_index} pane_id=#{pane_id} attempt=#{bumped}/#{State.poll_death_threshold()} poll_result=#{inspect(raw)}")
        capture_dump = AttachPane.capture_pane_dump(pane_id)

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

        AttachPane.dump_pipe_tail(state.slot_index)
        # The dead pane respawns below, so drop its ProcessReaper entry —
        # otherwise repeated death/respawn cycles accumulate stale pane
        # refs that the shutdown sweep would try (and fail) to kill.
        Aiur.ProcessReaper.unregister({:pane, pane_id})
        Events.session_changed(state.slot_index, nil)
        # Pane is dead — clear the registry's pane_id too.
        Events.visible_changed(state.slot_index, nil, nil)
        {:noreply, State.pane_died(state), {:continue, :spawn_attach}}
    end
  end

  def handle_info(:poll_session, state), do: {:noreply, %{state | poll_ref: nil}}

  def handle_info(:rebuild_now, state), do: {:noreply, state, {:continue, :start_serve}}

  def handle_info({:EXIT, pid, reason}, %{server_pid: pid} = state) do
    Logger.warning("opencode_slot phase=serve_exit elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} reason=#{inspect(reason)}")
    {:noreply, %{state | status: :failed, server_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Events.slot_terminated(state.slot_index, self())
    ServeLifecycle.terminate_cleanup(state)
  end

  defp do_attach(identifier, state) do
    cond do
      MapSet.member?(state.attached_identifiers, identifier) ->
        sid = if state.visible_identifier == identifier, do: state.visible_session_id, else: :attached
        {:ok, sid, state}

      State.identifier_known?(state, identifier) ->
        do_attach_known(identifier, state)

      true ->
        {:error, :identifier_unknown}
    end
  end

  defp do_attach_known(identifier, state) do
    span = Aiur.Perf.span_begin(:slot_do_attach, slot: state.slot_index, identifier: identifier)

    case Sessions.ensure(identifier, state.base_url) do
      {:ok, session_id} ->
        Aiur.Perf.span_end(span, slot: state.slot_index, identifier: identifier, session_id: session_id)
        new_state = %{state | attached_identifiers: MapSet.put(state.attached_identifiers, identifier)}
        # Note: leadoff render (`respawn_attach_with_session` to bind
        # the slot's attach pane to a session) is NOT done here. It's
        # driven explicitly by `AttachPool.kickoff_fan_out` calling
        # `Slot.set_visible/2` on the slot's intended leadoff
        # identifier — deterministic per slot. Doing it as a side effect
        # of whichever attach finished first under parallel boot caused
        # multiple slots to leadoff the same agent (race), leaving
        # other agents 🔘 (no painted pane) instead of ⚪.
        Aiur.Perf.event(:slot_attach_added, slot: state.slot_index, identifier: identifier, session_id: session_id)
        Logger.info("opencode_slot phase=attach slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id}")
        {:ok, session_id, new_state}

      {:error, reason} = err ->
        Aiur.Perf.span_end(span, result: :failed, slot: state.slot_index, identifier: identifier, reason: reason)
        err
    end
  end

  defp do_set_visible_call(identifier, from, state) do
    if State.identifier_known?(state, identifier) do
      case do_select(identifier, state) do
        {:ok, _session_id, new_state} ->
          Events.session_changed(new_state.slot_index, identifier)
          Events.visible_changed(new_state.slot_index, identifier, new_state.pane_id)
          # Also broadcast :slot_attach_added so AttachPool's
          # attached_slots[identifier] includes this slot.
          Events.attach_added(new_state.slot_index, identifier)
          {:reply, {:ok, new_state.pane_id}, schedule_poll(new_state)}

        {:error, _} = err ->
          {:reply, err, unclaim(state)}
      end
    else
      Logger.info("opencode_slot phase=identifier_miss elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier}")
      Aiur.Perf.event(:slot_identifier_miss, slot: state.slot_index, identifier: identifier)
      {:noreply, schedule_serve_rebuild(state, {from, identifier})}
    end
  end

  defp unclaim(%{status: :claimed} = state), do: %{state | status: :ready}
  defp unclaim(state), do: state

  defp do_select(identifier, state) do
    do_select_span = Aiur.Perf.span_begin(:slot_do_select, slot: state.slot_index, identifier: identifier)

    case Sessions.ensure_with_replay_span(identifier, state.base_url, state.slot_index) do
      {:ok, session_id} ->
        select_with_respawn(state, identifier, session_id, do_select_span)

      {:replay_failed, reason} ->
        span_kw = [result: :replay_failed, slot: state.slot_index, identifier: identifier, reason: reason]
        Aiur.Perf.span_end(do_select_span, span_kw)
        {:error, reason}

      {:writer_failed, err} ->
        Aiur.Perf.span_end(do_select_span, result: :writer_failed, slot: state.slot_index, identifier: identifier)
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
    attach_cmd = Protocol.attach_command(state.base_url, session_id)

    case respawn_attach_with_session(state, session_id, attach_cmd) do
      {:ok, new_pane_id} ->
        Logger.info("opencode_slot phase=select elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id} pane_id=#{new_pane_id}")
        span_kw = [slot: state.slot_index, identifier: identifier, session_id: session_id, pane_id: new_pane_id]
        Aiur.Perf.span_end(do_select_span, span_kw)
        {:ok, session_id, State.select_applied(state, identifier, session_id, new_pane_id)}

      {:error, _} = err ->
        Aiur.Perf.span_end(do_select_span, result: :respawn_failed, slot: state.slot_index, identifier: identifier)
        err
    end
  end

  defp respawn_attach_with_session(state, session_id, attach_cmd) do
    AttachPane.respawn_with_session(state, session_id, attach_cmd)
  end

  defp drain_pending_select(%{pending_select: nil} = state), do: state

  defp drain_pending_select(%{pending_select: {from, identifier}} = state) do
    case do_select(identifier, state) do
      {:ok, _session_id, new_state} ->
        Events.session_changed(new_state.slot_index, identifier)
        # Match the non-rebuild path's broadcasts: visible_changed so
        # the renderer marker flips ⏳/🔘 → ⚪, and attach_added so the
        # warm consume path finds this slot for the new identifier
        # (otherwise the next Enter falls through to placeholder).
        Events.visible_changed(new_state.slot_index, identifier, new_state.pane_id)
        Events.attach_added(new_state.slot_index, identifier)
        GenServer.reply(from, {:ok, new_state.pane_id})
        schedule_poll(%{new_state | pending_select: nil})

      {:error, _} = err ->
        GenServer.reply(from, err)
        %{state | pending_select: nil}
    end
  end

  defp drain_pending_attaches(%{pending_attaches: ms} = state) do
    if MapSet.size(ms) == 0,
      do: state,
      else: Enum.reduce(ms, %{state | pending_attaches: MapSet.new()}, &retry_pending_attach/2)
  end

  defp retry_pending_attach(id, acc) do
    case do_attach(id, acc) do
      {:ok, _session_id, new_acc} ->
        Events.attach_added(new_acc.slot_index, id)
        Aiur.Perf.event(:slot_attach_retry_succeeded, slot: new_acc.slot_index, identifier: id)
        new_acc

      {:error, reason} ->
        Aiur.Perf.event(:slot_attach_retry_failed, slot: acc.slot_index, identifier: id, reason: reason)
        acc
    end
  end

  defp schedule_serve_rebuild(state, nil),
    do: do_schedule_serve_rebuild(state, nil, state.known_identifiers)

  defp schedule_serve_rebuild(state, {_from, identifier} = pending),
    do: do_schedule_serve_rebuild(state, pending, MapSet.put(state.known_identifiers, identifier))

  defp do_schedule_serve_rebuild(state, pending, next_known) do
    ServeLifecycle.teardown_generation(state)
    _ = cancel_poll(state.poll_ref)
    # Kick the rebuild via a self-message so we can return :noreply now
    # and the next mailbox dispatch re-enters via :rebuild_now → start_serve.
    send(self(), :rebuild_now)
    State.rebuild_reset(state, pending, next_known)
  end

  defp schedule_poll(%{status: :active} = state) do
    # Cancel any prior pending poll timer before scheduling a new one.
    # Otherwise rapid back-to-back swaps stack multiple Process.send_after
    # timers; they all fire 500ms later within milliseconds of each
    # other, defeating the consecutive-failures debounce and false-
    # tearing the slot down.
    _ = cancel_poll(state.poll_ref)
    %{state | poll_ref: Process.send_after(self(), :poll_session, poll_interval_ms())}
  end

  defp schedule_poll(state), do: state

  defp cancel_poll(nil), do: nil

  defp cancel_poll(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp process_name(slot_index), do: :"#{__MODULE__}-#{slot_index}"
  defp poll_interval_ms, do: Application.get_env(:aiur, :slot_poll_interval_ms, @default_poll_interval_ms)
end
