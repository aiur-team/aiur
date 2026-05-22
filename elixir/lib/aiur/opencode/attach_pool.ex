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

  alias Aiur.Opencode.{Protocol, Slot, SlotSupervisor, SlotRegistry}
  alias Aiur.Tmux

  @topic "attach_pool"

  defstruct slots_ready?: false,
            seeded_identifiers: MapSet.new(),
            attachments: %{}

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
        new_state = put_in(state.attachments[identifier], new_att)

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

        new_state = update_in(state.attachments, &Map.delete(&1, identifier))
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
      case SlotSupervisor.acquire_slot() do
        {slot_index, slot_pid} when is_integer(slot_index) ->
          spawn_warm_attach(pool, identifier, slot_index, slot_pid)

          att = Map.fetch!(acc.attachments, identifier)
          new_att = %{att | status: :warming, slot_index: slot_index}
          put_in(acc.attachments[identifier], new_att)

        {:error, :no_ready_slot} ->
          # Stop here — no more slots free this round. Remaining
          # identifiers stay :pending; the next :slot_ready event
          # (release back) will retry.
          acc
      end
    end)
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
          # Also resize the hidden pane to roughly the size it will
          # have when moved to the visible window. opencode-attach
          # re-renders from scratch on resize, so if we don't pre-
          # size, the user pressing Enter triggers another 5-7 s
          # render after move-pane. Pre-sizing avoids that.
          _ = Tmux.command(Tmux, "resize-pane -t #{pane_id} -x 110 -y 30")

          # Wait for the message-turn marker `Build · issue-` to
          # appear in the pane before declaring warm.
          case wait_for_paint(pane_id, 30_000) do
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

              # The attach spawned but never painted — best effort:
              # mark it warm anyway since the pane DOES exist. User
              # might see a slow render but at least gets opencode.
              send(pool, {:attach_warmed, identifier, slot_index, pane_id})
          end

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
        content = Enum.join(lines, "\n")

        if String.contains?(content, "Build · issue-") do
          :ok
        else
          if System.monotonic_time(:millisecond) >= deadline do
            :timeout
          else
            Process.sleep(@paint_poll_interval_ms)
            do_wait_for_paint(pane_id, deadline)
          end
        end

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@paint_poll_interval_ms)
          do_wait_for_paint(pane_id, deadline)
        end
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
  # Unused but kept so future code that wants the canonical attach
  # command can reuse Protocol's escape logic.
  def _attach_command_for(base_url, session_id),
    do: Protocol.attach_command(base_url, session_id)
end
