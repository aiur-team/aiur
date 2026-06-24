defmodule Aiur.Opencode.SlotPolicy do
  @moduledoc """
  Parallel pre-warm orchestrator.

  Starts every slot up to `target_count` concurrently at boot. With
  lazy expansion (one slot per user open), only one slot was warm when
  the user pressed Enter on the second/third agent — the open then
  paid a 5-7 s respawn because the matching leadoff slot wasn't ready
  yet. Parallel boot front-loads that cost into application startup so
  every ⚪ open is instant.

  Subscribes to `Aiur.Opencode.Slot.slots_topic/0`. On
  `{:slot_ready, target_count}` emits a `:slot_chain_complete` perf
  event for telemetry.

  ## Warm pool vs. hard cap

  `pre_warmed_sessions` sizes only the WARM POOL — how many slots
  auto-boot at startup (`target_count`). It is NOT the ceiling on how
  many opencode instances can exist. Beyond the warm pool, an open with
  no ready slot grows the pool one cold slot at a time (via `grow_slot/0`)
  up to `max_slots` — the same `max(grid, max_concurrent_agents)` value
  `PaneManager` uses for its slot bookkeeping, so every grown slot still
  has a layout cell.

  ## Public API

    * `bump/0` — kept for backward compatibility with PaneManager's
      post-open call site. Now a no-op since every slot is already
      starting at boot.
    * `grow_slot/0` — start the next slot on demand (cold), up to
      `max_slots`. Returns `{:ok, index, pid}`, `{:error, :at_capacity}`,
      or `{:error, reason}`.
    * `highest_started/0` — index of the highest slot started so far.
    * `target_count/0` — warm-pool size (auto-booted at startup).
    * `max_slots/0` — hard cap on total slots.
  """

  use GenServer
  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{Slot, SlotSupervisor}

  defstruct target_count: 0, highest_started: 0, max_slots: 0, pubsub: Aiur.PubSub

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Start the next opencode slot in sequence (lazy expansion).

  Returns `:ok` regardless of whether a new slot actually started:
  callers should not block on the response. Use `SlotSupervisor` /
  `SlotRegistry` to introspect actual slot state.

  Idempotent and safe to call from concurrent contexts — the policy
  serializes bump decisions in its own mailbox.
  """
  @spec bump() :: :ok
  @spec bump(GenServer.server()) :: :ok
  def bump(server \\ __MODULE__) do
    GenServer.cast(server, :bump)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Return the highest slot index started by this policy.

  Used by `PaneManager` to decide whether to call `bump/0` after a
  successful pane open (don't bump past `target_count`; don't bump
  while a previous bump is still in flight).
  """
  @spec highest_started() :: non_neg_integer()
  @spec highest_started(GenServer.server()) :: non_neg_integer()
  def highest_started(server \\ __MODULE__) do
    GenServer.call(server, :highest_started, 1_000)
  catch
    :exit, _ -> 0
  end

  @doc "Warm-pool size — how many slots auto-boot at startup."
  @spec target_count() :: non_neg_integer()
  @spec target_count(GenServer.server()) :: non_neg_integer()
  def target_count(server \\ __MODULE__) do
    GenServer.call(server, :target_count, 1_000)
  catch
    :exit, _ -> 0
  end

  @doc "Hard cap on total slots (warm pool + on-demand growth)."
  @spec max_slots() :: non_neg_integer()
  @spec max_slots(GenServer.server()) :: non_neg_integer()
  def max_slots(server \\ __MODULE__) do
    GenServer.call(server, :max_slots, 1_000)
  catch
    :exit, _ -> 0
  end

  @doc """
  Start the next slot on demand, cold, up to `max_slots`.

  Called by `SlotSupervisor.acquire_slot_or_grow/0` when an open finds
  no ready slot and every existing slot is busy — the warm pool is
  exhausted but the hard cap hasn't been reached. Index allocation is
  serialized through this GenServer's mailbox so concurrent opens never
  collide on the same slot index.

  Returns `{:ok, slot_index, pid}` on a fresh start, `{:error, :at_capacity}`
  when `max_slots` is already reached, or `{:error, reason}` if the start
  itself failed.
  """
  @spec grow_slot() :: {:ok, pos_integer(), pid()} | {:error, term()}
  @spec grow_slot(GenServer.server()) :: {:ok, pos_integer(), pid()} | {:error, term()}
  def grow_slot(server \\ __MODULE__) do
    GenServer.call(server, :grow_slot, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    target_count =
      Keyword.get_lazy(opts, :target_count, fn ->
        default_target_count()
      end)

    max_slots =
      Keyword.get_lazy(opts, :max_slots, fn ->
        default_max_slots()
      end)

    pubsub = Keyword.get(opts, :pubsub, Aiur.PubSub)

    Logger.info("opencode_slot_policy phase=init elapsed_ms=#{Boot.elapsed_ms()} target_count=#{target_count} max_slots=#{max_slots} mode=parallel")

    :ok = Phoenix.PubSub.subscribe(pubsub, Slot.slots_topic())

    send(self(), :start_all_slots)

    {:ok,
     %__MODULE__{
       target_count: target_count,
       highest_started: 0,
       max_slots: max_slots,
       pubsub: pubsub
     }}
  end

  @impl true
  def handle_info(:start_all_slots, %{target_count: 0} = state) do
    Logger.info("opencode_slot_policy phase=chain_skipped target_count=0")
    {:noreply, state}
  end

  def handle_info(:start_all_slots, %{target_count: target, pubsub: pubsub} = state) do
    Aiur.Perf.event(:slot_policy_start_first, target_count: target)

    Logger.info("opencode_slot_policy phase=parallel_boot_start elapsed_ms=#{Boot.elapsed_ms()} target=#{target}")

    highest =
      1..target
      |> Enum.reduce(0, fn slot_index, acc ->
        case SlotSupervisor.start_slot(slot_index) do
          {:ok, _pid} ->
            Phoenix.PubSub.broadcast(
              pubsub,
              Slot.slots_topic(),
              {:slot_starting, slot_index}
            )

            max(acc, slot_index)

          {:error, reason} ->
            Logger.warning("opencode_slot_policy phase=parallel_boot_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{slot_index} reason=#{inspect(reason)}")

            acc
        end
      end)

    Logger.info("opencode_slot_policy phase=parallel_boot_dispatched elapsed_ms=#{Boot.elapsed_ms()} highest=#{highest}")

    {:noreply, %{state | highest_started: highest}}
  end

  def handle_info({:slot_ready, n}, %{target_count: target} = state)
      when n >= target do
    if n == target do
      Logger.info("opencode_slot_policy phase=chain_complete elapsed_ms=#{Boot.elapsed_ms()} slots=#{target}")

      Aiur.Perf.event(:slot_chain_complete, slots: target)
    end

    {:noreply, state}
  end

  def handle_info({:slot_ready, _n}, state) do
    {:noreply, state}
  end

  # Old PubSub event names from U1 / pre-U3 — keep no-op handlers so we
  # don't crash when subscribers from other modules emit.
  def handle_info({:slot_session_changed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_attach_added, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_attach_removed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_visible_changed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # All slots are dispatched at boot now, so bump has no work to do.
  # Kept as a no-op so existing call sites in PaneManager continue to
  # compile without conditionals.
  @impl true
  def handle_cast(:bump, state) do
    Aiur.Perf.event(:slot_policy_bump_noop,
      reason: :parallel_boot,
      highest_started: state.highest_started,
      target: state.target_count
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:highest_started, _from, state) do
    {:reply, state.highest_started, state}
  end

  def handle_call(:target_count, _from, state) do
    {:reply, state.target_count, state}
  end

  def handle_call(:max_slots, _from, state) do
    {:reply, state.max_slots, state}
  end

  def handle_call(:grow_slot, _from, %{highest_started: highest, max_slots: max} = state)
      when highest >= max do
    Aiur.Perf.event(:slot_policy_grow_at_capacity, highest_started: highest, max_slots: max)
    {:reply, {:error, :at_capacity}, state}
  end

  def handle_call(:grow_slot, _from, %{highest_started: highest, pubsub: pubsub} = state) do
    next = highest + 1

    case SlotSupervisor.start_slot(next) do
      {:ok, pid} ->
        Phoenix.PubSub.broadcast(pubsub, Slot.slots_topic(), {:slot_starting, next})

        Logger.info("opencode_slot_policy phase=grow elapsed_ms=#{Boot.elapsed_ms()} slot=#{next} max_slots=#{state.max_slots}")

        Aiur.Perf.event(:slot_policy_grow, slot: next, max_slots: state.max_slots)

        {:reply, {:ok, next, pid}, %{state | highest_started: next}}

      {:error, reason} = err ->
        Logger.warning("opencode_slot_policy phase=grow_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{next} reason=#{inspect(reason)}")

        {:reply, err, state}
    end
  end

  # Pre-warm slot count is governed by the new `pre_warmed_sessions`
  # `.aiurconfig` setting (default 3). Capped at `max_concurrent_agents`
  # because spawning more pre-warm slots than the orchestrator will
  # ever fill with active agents wastes opencode-serve processes.
  # `pre_warmed_sessions = 0` is valid: no slots boot, every open
  # goes through the cold placeholder path.
  defp default_target_count do
    pre_warmed = Aiur.Config.pre_warmed_sessions()
    max_agents = Aiur.Config.max_concurrent_agents()
    min(pre_warmed, max_agents)
  rescue
    _ -> 3
  end

  # Hard cap on total slots. Mirrors `PaneManager`'s `slot_count` —
  # `max(grid, max_concurrent_agents)` — so every slot the pool can grow
  # to still has a layout cell (PaneManager seeds `slot_panes` and lays
  # out `1..slot_count`). Growing past it would leave a slot with no
  # visual home. The warm pool (`target_count`) is independent and
  # usually smaller.
  defp default_max_slots do
    grid = Aiur.Config.max_vertical_panes() * 2 - 1
    max_agents = Aiur.Config.max_concurrent_agents()
    max(grid, max_agents)
  rescue
    _ -> 3
  end
end
