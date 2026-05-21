defmodule Aiur.Opencode.SlotPolicy do
  @moduledoc """
  Chain pre-warm orchestrator.

  Subscribes to `Aiur.PubSub` topic `Aiur.Opencode.Slot.slots_topic/0`.
  At init, asks `SlotSupervisor` to start slot 1. On every
  `{:slot_ready, n}` broadcast it asks the supervisor to start slot N+1,
  up to `target_count` (default `(2 * max_vertical_panes) - 1`).

  Net effect: the user gets sub-100 ms opens for every slot they reach,
  because by the time they get there the slot is already warm.

  Idempotent: receiving the same `{:slot_ready, n}` twice does not
  start N+1 twice. Tracks "highest slot started" in state.
  """

  use GenServer
  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.{Slot, SlotSupervisor}

  defstruct target_count: 0, highest_started: 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    target_count =
      Keyword.get_lazy(opts, :target_count, fn ->
        default_target_count()
      end)

    Logger.info(
      "opencode_slot_policy phase=init elapsed_ms=#{Boot.elapsed_ms()} target_count=#{target_count}"
    )

    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())

    # Kick the chain off immediately.
    send(self(), :start_first_slot)

    {:ok, %__MODULE__{target_count: target_count, highest_started: 0}}
  end

  @impl true
  def handle_info(:start_first_slot, %{target_count: 0} = state) do
    Logger.info("opencode_slot_policy phase=chain_skipped target_count=0")
    {:noreply, state}
  end

  def handle_info(:start_first_slot, state) do
    case SlotSupervisor.start_slot(1) do
      {:ok, _pid} ->
        Logger.info(
          "opencode_slot_policy phase=chain_start elapsed_ms=#{Boot.elapsed_ms()} slot=1"
        )

        {:noreply, %{state | highest_started: 1}}

      {:error, reason} ->
        Logger.warning(
          "opencode_slot_policy phase=chain_start_failed elapsed_ms=#{Boot.elapsed_ms()} slot=1 reason=#{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:slot_ready, n},
        %{target_count: target, highest_started: highest} = state
      )
      when n >= target do
    if n == target do
      Logger.info(
        "opencode_slot_policy phase=chain_complete elapsed_ms=#{Boot.elapsed_ms()} slots=#{target}"
      )
    end

    _ = highest
    {:noreply, state}
  end

  def handle_info({:slot_ready, n}, %{highest_started: highest} = state) when n < highest do
    # Stale event for a slot we've already advanced past — no-op.
    {:noreply, state}
  end

  def handle_info({:slot_ready, n}, state) do
    next = n + 1

    case SlotSupervisor.start_slot(next) do
      {:ok, _pid} ->
        Logger.info(
          "opencode_slot_policy phase=chain_advance elapsed_ms=#{Boot.elapsed_ms()} slot=#{next}"
        )

        {:noreply, %{state | highest_started: next}}

      {:error, reason} ->
        Logger.warning(
          "opencode_slot_policy phase=chain_advance_failed elapsed_ms=#{Boot.elapsed_ms()} slot=#{next} reason=#{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_info({:slot_session_changed, _slot_index, _identifier}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp default_target_count do
    max_vertical_panes = Aiur.Config.max_vertical_panes()
    max_vertical_panes * 2 - 1
  rescue
    _ -> 5
  end
end
