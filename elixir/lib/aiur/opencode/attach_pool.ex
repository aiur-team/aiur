defmodule Aiur.Opencode.AttachPool do
  @moduledoc """
  Per-agent opencode-attach pre-warm pool.

  The opencode-attach process inside each chat pane has a 5-7 s cold
  start — Bun runtime boot + WebSocket handshake with opencode-serve
  + SQLite session-row read + first TUI paint. Until we work around
  that startup, the only way to give the user a truly instant chat
  pane is to keep an attach process already booted and bound to the
  agent's session, then move-pane it to visible on Enter.

  AttachPool runs that pre-warm. After:

    1. Slot pre-warm completes (`SlotPolicy` emits `:slot_chain_complete`)
    2. The agent list has at least one active agent

  the pool acquires one slot per active identifier and spawns
  `opencode attach <url> --session <id>` into `aiur-hidden`, parallel
  across all active agents. As each attach process finishes its first
  paint (detected via tmux pane content), the pool flips that
  identifier's status to `:warm` and broadcasts `{:attach_warm, id, pane_id, slot_index}`
  on `Aiur.PubSub` topic `attach_pool`.

  PaneManager consults the pool on user-open. If the identifier is
  `:warm`, PaneManager moves the pane to visible directly (~50 ms).
  Otherwise it falls back to the placeholder + respawn path (~5-7 s
  cold).

  ## State machine per identifier

      :pending  → not yet picked up (no slot acquired)
      :warming  → opencode-attach spawned, polling pane for first paint
      :warm     → first paint detected, pane sits in aiur-hidden
      :consumed → user opened it; the warm pane has been moved to
                  visible. Subsequent attempts to open this identifier
                  must respawn.

  Re-warming a `:consumed` identifier (so the user can open it again
  later) is left for a future enhancement.
  """

  use GenServer
  require Logger

  alias Aiur.Opencode.{Protocol, Slot, SlotRegistry, SlotSupervisor}
  alias Aiur.Tmux

  @topic "attach_pool"

  defstruct slots_ready?: false,
            seeded_identifiers: MapSet.new(),
            attachments: %{},
            # Slot indexes currently held by an in-flight warm Task or
            # by a :warm attachment in the pool. SlotSupervisor.acquire_slot
            # returns the lowest-indexed :ready slot; without this guard,
            # back-to-back acquire calls in maybe_warm_pending return the
            # SAME slot (the slot's status doesn't transition to :active
            # until the dispatched Task's Slot.select message lands).
            # Two warmings would then collide on slot 1 — both fight for
            # the pane, both hit the 30 s paint timeout.
            claimed_slots: MapSet.new()

  @type attachment_status :: :pending | :warming | :warm | :consumed
  @type attachment :: %{
          status: attachment_status(),
          slot_index: pos_integer() | nil,
          pane_id: String.t() | nil,
          identifier: String.t()
        }

  ## Public API ----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "PubSub topic for warm-state changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Seed the pool with the set of agent identifiers that should have
  a warm attach pane ready. Called from `Aiur.AgentList.App` whenever
  the active identifier list changes. Pool ignores duplicates.
  """
  @spec seed(GenServer.server(), [String.t()]) :: :ok
  def seed(server \\ __MODULE__, identifiers) when is_list(identifiers) do
    GenServer.cast(server, {:seed, identifiers})
  end

  @doc """
  Try to acquire a warm pre-attached pane for `identifier`. Returns
  `{:ok, %{slot_index: N, pane_id: \"%X\"}}` and atomically transitions
  the attachment to `:consumed`; or `:miss` if no warm attach is
  available (PaneManager falls back to placeholder + respawn).
  """
  @spec consume(GenServer.server(), String.t()) ::
          {:ok, %{slot_index: pos_integer(), pane_id: String.t()}} | :miss
  def consume(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.call(server, {:consume, identifier})
  catch
    :exit, _ -> :miss
  end

  @doc "Returns the full attachment map (identifier -> attachment struct)."
  @spec snapshot(GenServer.server()) :: %{optional(String.t()) => attachment()}
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 1_000)
  catch
    :exit, _ -> %{}
  end

  ## GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:seed, identifiers}, state) do
    new_state = absorb_seed(state, identifiers)
    {:noreply, maybe_warm_pending(new_state)}
  end

  @impl true
  def handle_call({:consume, identifier}, _from, state) do
    case Map.get(state.attachments, identifier) do
      %{status: :warm, slot_index: slot_index, pane_id: pane_id} = att
      when is_integer(slot_index) and is_binary(pane_id) ->
        new_att = %{att | status: :consumed}

        new_state =
          state
          |> put_in([Access.key!(:attachments), identifier], new_att)
          # Release the slot claim — the warm pane is now visible to
          # the user and the slot is :active under their open. If the
          # user closes the pane, that slot can be re-warmed for a
          # different identifier (future enhancement).
          |> Map.update!(:claimed_slots, &MapSet.delete(&1, slot_index))

        Aiur.Perf.event(:attach_pool_hit,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        broadcast_event({:attach_consumed, identifier, pane_id, slot_index})
        {:reply, {:ok, %{slot_index: slot_index, pane_id: pane_id}}, new_state}

      _ ->
        Aiur.Perf.event(:attach_pool_miss, identifier: identifier)
        {:reply, :miss, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.attachments, state}
  end

  @impl true
  def handle_info({:slot_ready, _slot_index}, state) do
    chain_target = safe_slot_count_target()
    ready_count = ready_slot_count()
    slots_ready? = ready_count >= chain_target

    new_state = %{state | slots_ready?: slots_ready?}

    new_state =
      if slots_ready? and not state.slots_ready? do
        Aiur.Perf.event(:attach_pool_slots_ready, ready_count: ready_count)

        # Widen aiur-hidden ONCE before any warm spawns — so panes are
        # created at the target geometry and opencode-attach doesn't
        # re-render mid-boot when we resize the window later.
        # Previously this ran per-warm AFTER each pane spawned, which
        # triggered an opencode-attach resize redraw and added 5-7 s
        # to first paint.
        ensure_hidden_geometry()

        maybe_warm_pending(new_state)
      else
        new_state
      end

    {:noreply, new_state}
  end

  def handle_info({:slot_session_changed, _slot_index, _identifier}, state) do
    {:noreply, state}
  end

  def handle_info({:attach_warmed, identifier, slot_index, pane_id}, state) do
    case Map.get(state.attachments, identifier) do
      %{status: :warming} = att ->
        new_att = %{att | status: :warm, slot_index: slot_index, pane_id: pane_id}
        new_state = put_in(state.attachments[identifier], new_att)

        Aiur.Perf.event(:attach_pool_warm,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        broadcast_event({:attach_warm, identifier, pane_id, slot_index})
        {:noreply, new_state}

      _ ->
        # Stale message — identifier may have been consumed/removed
        # before its warm-up finished. Best effort: kill the orphan
        # pane so we don't leak tmux panes.
        if is_binary(pane_id) do
          _ = Tmux.command(Tmux, "kill-pane -t #{pane_id}")
        end

        {:noreply, state}
    end
  end

  def handle_info({:attach_failed, identifier, slot_index, reason}, state) do
    case Map.get(state.attachments, identifier) do
      %{status: :warming} = _att ->
        Aiur.Perf.event(:attach_pool_failed,
          identifier: identifier,
          slot: slot_index,
          reason: reason
        )

        new_state =
          state
          |> Map.update!(:attachments, &Map.delete(&1, identifier))
          # Release the claim so the slot can be retried (e.g. with a
          # different identifier, or this one once the upstream issue
          # is fixed).
          |> Map.update!(:claimed_slots, &MapSet.delete(&1, slot_index))

        # Broadcast so AgentList can clear the ⏳ warming marker —
        # otherwise rows whose paint timed out stay hourglass forever
        # because warming_identifiers is never trimmed on failure.
        broadcast_event({:attach_failed, identifier, slot_index, reason})
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals -----------------------------------------------------------

  defp absorb_seed(state, identifiers) do
    new_attachments =
      Enum.reduce(identifiers, state.attachments, fn id, acc ->
        if Map.has_key?(acc, id) do
          acc
        else
          Map.put(acc, id, %{
            status: :pending,
            slot_index: nil,
            pane_id: nil,
            identifier: id
          })
        end
      end)

    new_seeded = MapSet.union(state.seeded_identifiers, MapSet.new(identifiers))

    %{state | attachments: new_attachments, seeded_identifiers: new_seeded}
  end

  defp maybe_warm_pending(%{slots_ready?: false} = state), do: state

  defp maybe_warm_pending(state) do
    pending =
      state.attachments
      |> Enum.filter(fn {_id, att} -> att.status == :pending end)
      |> Enum.map(fn {id, _} -> id end)

    pool = self()

    Enum.reduce(pending, state, fn identifier, acc ->
      case acquire_unclaimed_slot(acc.claimed_slots) do
        {slot_index, slot_pid} when is_integer(slot_index) ->
          spawn_warm_attach(pool, identifier, slot_index, slot_pid)

          att = Map.fetch!(acc.attachments, identifier)
          new_att = %{att | status: :warming, slot_index: slot_index}

          acc
          |> put_in([Access.key!(:attachments), identifier], new_att)
          |> Map.update!(:claimed_slots, &MapSet.put(&1, slot_index))

        {:error, :no_ready_slot} ->
          # Stop here — no more slots free this round. Remaining
          # identifiers stay :pending; the next :slot_ready event
          # (release back) will retry.
          acc
      end
    end)
  end

  # Walk SlotRegistry directly to find an :ready slot whose index is
  # NOT in `claimed`. This is what `SlotSupervisor.acquire_slot/0`
  # does but with the claim-set guard so back-to-back calls in
  # `maybe_warm_pending` can't return the same slot twice before the
  # async Task transitions it to :active.
  defp acquire_unclaimed_slot(claimed) do
    ready =
      SlotRegistry.all()
      |> Enum.reject(fn {idx, _pid} -> MapSet.member?(claimed, idx) end)
      |> Enum.map(fn {idx, pid} -> {idx, pid, Slot.snapshot(pid)} end)
      |> Enum.filter(fn {_idx, _pid, snap} -> Map.get(snap, :status) == :ready end)

    case ready do
      [] ->
        {:error, :no_ready_slot}

      candidates ->
        {idx, pid, _snap} = Enum.min_by(candidates, fn {idx, _, _} -> idx end)
        {idx, pid}
    end
  end

  defp spawn_warm_attach(pool, identifier, slot_index, slot_pid) do
    # Tell AgentList we're warming this identifier so it can suppress
    # the false "● open pane" marker that fires from
    # :slot_session_changed during Slot.select. The pane isn't visible
    # — it's mid-warm.
    broadcast_event({:attach_warming, identifier, slot_index})

    Task.start(fn ->
      span =
        Aiur.Perf.span_begin(:attach_pool_warm_attach,
          identifier: identifier,
          slot: slot_index
        )

      case Slot.select(slot_pid, identifier) do
        {:ok, pane_id} ->
          # Slot.select returned the pane_id, but opencode-attach
          # inside that pane is still booting (Node.js + WS handshake
          # + SQLite session-row read + first TUI paint takes 5-7 s).
          # If we mark warm now, the user sees a black/loading pane
          # for 7 s when they press Enter — defeating the purpose.
          #
          # Wait for the message-turn marker `Build · issue-` to
          # appear in the pane before declaring warm.
          finish_warm_attach_after_paint(pool, span, identifier, slot_index, pane_id)

        {:error, reason} ->
          Aiur.Perf.span_end(span,
            result: :failed,
            identifier: identifier,
            slot: slot_index,
            reason: reason
          )

          send(pool, {:attach_failed, identifier, slot_index, reason})
      end
    end)
  end

  defp finish_warm_attach_after_paint(pool, span, identifier, slot_index, pane_id) do
    case wait_for_paint(pane_id, 20_000) do
      :ok ->
        Aiur.Perf.span_end(span,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        send(pool, {:attach_warmed, identifier, slot_index, pane_id})

      :timeout ->
        Aiur.Perf.span_end(span,
          result: :paint_timeout,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        # Paint never landed within the budget. Treat as failure
        # — marking warm now would lie to the user (⚡ promises
        # instant open, but a never-painted attach renders cold
        # at move-pane time). Drop the attachment so the next
        # seed can retry on a fresh slot.
        send(pool, {:attach_failed, identifier, slot_index, :paint_timeout})
    end
  end

  # Widen the aiur-hidden window so each warm-attach pane has at
  # least ~110 cols to render in. The window normally inherits the
  # client size (~220 cols), and tmux splits panes 50/50 — so 5 co-
  # located opencode-attach panes get squished to 1-44 cols each,
  # and opencode-attach never paints in that little space.
  #
  # `resize-window -A` auto-sizes to fit attached clients; for our
  # hidden window with no attached client we pin a large fixed
  # width via `resize-window -x`. tmux silently caps to the max
  # available width if our target exceeds physical capacity.
  #
  # Idempotent: if the window is already wide enough we no-op.
  @hidden_target_width 600
  @hidden_target_height 60

  defp ensure_hidden_geometry do
    target = Aiur.Config.max_vertical_panes() * 2 - 1
    desired_width = max(target * 110, @hidden_target_width)

    case Tmux.command(Tmux, "display-message -p -t aiur-orangekid-default:aiur-hidden \#{window_width}") do
      {:ok, [width_str | _]} ->
        current = width_str |> String.trim() |> String.to_integer()

        if current < desired_width do
          _ =
            Tmux.command(
              Tmux,
              "resize-window -t aiur-orangekid-default:aiur-hidden -x #{desired_width} -y #{@hidden_target_height}"
            )

          # Re-layout so existing panes get equal share of the new width.
          _ =
            Tmux.command(
              Tmux,
              "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal"
            )
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Poll the pane for the `Build · issue-` marker — opencode prints it
  # once it has rendered the conversation. Returns :ok when visible
  # or :timeout after the budget.
  @paint_poll_interval_ms 100

  defp wait_for_paint(pane_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_paint(pane_id, deadline)
  end

  defp do_wait_for_paint(pane_id, deadline) do
    case Tmux.command(Tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} ->
        check_paint_or_retry(pane_id, deadline, Enum.join(lines, "\n"))

      _ ->
        retry_wait_for_paint(pane_id, deadline)
    end
  end

  defp check_paint_or_retry(pane_id, deadline, content) do
    if String.contains?(content, "Build · issue-") do
      :ok
    else
      retry_wait_for_paint(pane_id, deadline)
    end
  end

  defp retry_wait_for_paint(pane_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      Process.sleep(@paint_poll_interval_ms)
      do_wait_for_paint(pane_id, deadline)
    end
  end

  defp broadcast_event(payload) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, @topic, payload)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ready_slot_count do
    SlotRegistry.all()
    |> Enum.count(fn {_idx, pid} ->
      case Slot.snapshot(pid) do
        %{status: status} -> status in [:ready, :active]
        _ -> false
      end
    end)
  end

  defp safe_slot_count_target do
    Aiur.Config.max_vertical_panes() * 2 - 1
  rescue
    _ -> 5
  end

  @doc false
  @spec _attach_command_for(String.t(), String.t()) :: String.t()
  def _attach_command_for(base_url, session_id),
    do: Protocol.attach_command(base_url, session_id)
end
