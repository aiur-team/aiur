defmodule Aiur.Opencode.SlotPolicy do
  @moduledoc """
  Lazy-expansion pre-warm orchestrator.

  Boots Slot 1 at startup. Subsequent slots warm on demand via
  `bump/0`, typically called by `PaneManager` after the user opens a
  new chat pane. The Nth slot warms when the user has opened N-1
  panes. Cap is `target_count` (default `max_vertical_panes * 2 - 1`).

  Subscribes to `Aiur.Opencode.Slot.slots_topic/0`. On
  `{:slot_ready, target_count}` emits a `:slot_chain_complete` perf
  event for telemetry.

  ## Public API

    * `bump/0` — start the next slot. Idempotent under concurrent
      calls: at most one slot advances per bump.
    * `highest_started/0` — index of the highest slot started so far.
    * `target_count/0` — upper bound on slots.
  """

  use GenServer
  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{Slot, SlotSupervisor}

  defstruct target_count: 0, highest_started: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  @doc "Upper bound on slots this policy will start."
  @spec target_count() :: non_neg_integer()
  @spec target_count(GenServer.server()) :: non_neg_integer()
  def target_count(server \\ __MODULE__) do
    GenServer.call(server, :target_count, 1_000)
  catch
    :exit, _ -> 0
  end

  @impl true
  def init(opts) do
    target_count =
      Keyword.get_lazy(opts, :target_count, fn ->
        default_target_count()
      end)

    Logger.info("opencode_slot_policy phase=init elapsed_ms=#{Boot.elapsed_ms()} target_count=#{target_count} mode=lazy")

    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())

    send(self(), :start_first_slot)

    {:ok, %__MODULE__{target_count: target_count, highest_started: 0}}
  end

  @impl true
  def handle_info(:start_first_slot, %{target_count: 0} = state) do
    Logger.info("opencode_slot_policy phase=chain_skipped target_count=0")
    {:noreply, state}
  end

  def handle_info(:start_first_slot, %{target_count: target} = state) do
    Aiur.Perf.event(:slot_policy_start_first, target_count: target)

    Logger.info("opencode_slot_policy phase=first_slot_start elapsed_ms=#{Boot.elapsed_ms()} target=#{target}")

    case SlotSupervisor.start_slot(1) do
      {:ok, _pid} ->
        {:noreply, %{state | highest_started: 1}}

      {:error, reason} ->
        Logger.warning("opencode_slot_policy phase=first_slot_failed elapsed_ms=#{Boot.elapsed_ms()} slot=1 reason=#{inspect(reason)}")

        {:noreply, state}
    end
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

  @impl true
  def handle_cast(:bump, %{target_count: target, highest_started: highest} = state)
      when highest >= target do
    # Already at cap. No-op.
    Aiur.Perf.event(:slot_policy_bump_noop,
      reason: :at_cap,
      highest_started: highest,
      target: target
    )

    {:noreply, state}
  end

  def handle_cast(:bump, %{highest_started: highest} = state) do
    next = highest + 1

    Aiur.Perf.event(:slot_policy_bumped, slot: next)

    Logger.info("opencode_slot_policy phase=bump elapsed_ms=#{Boot.elapsed_ms()} slot=#{next}")

    case SlotSupervisor.start_slot(next) do
      {:ok, _pid} ->
        {:noreply, %{state | highest_started: next}}

      {:error, reason} ->
        Logger.warning("opencode_slot_policy phase=bump_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{next} reason=#{inspect(reason)}")

        # Don't increment highest_started so a retry bumps the same
        # slot.
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:highest_started, _from, state) do
    {:reply, state.highest_started, state}
  end

  def handle_call(:target_count, _from, state) do
    {:reply, state.target_count, state}
  end

  defp default_target_count do
    max_vertical_panes = Aiur.Config.max_vertical_panes()
    max_vertical_panes * 2 - 1
  rescue
    _ -> 5
  end
end
