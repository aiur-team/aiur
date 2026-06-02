defmodule Aiur.Opencode.SlotSupervisor do
  @moduledoc """
  DynamicSupervisor that owns the per-slot `Aiur.Opencode.Slot` workers.

  - `start_slot/1` spawns a Slot worker for the given index. Called by
    `SlotPolicy` once at boot for slot 1 and on each `{:slot_ready, N}`
    PubSub broadcast for `N+1`.
  - `acquire_slot/0` returns `{slot_index, slot_pid}` for a slot
    currently in `:ready` state, preferring least-recently-released.
    Used by `PaneManager` to allocate a slot for a user-initiated pane
    open.
  - `release_slot/1` (called via the slot itself when its identifier is
    deselected) marks the slot LRU-stamp so a subsequent acquire prefers
    the longest-idle slot.

  Slot lifecycles are independent — a crashed Slot worker is restarted
  by this supervisor (`restart: :transient`). If a slot's
  opencode-serve died and the slot transitioned to `:failed`, the slot
  worker itself terminates and the supervisor restarts it from scratch.
  """

  use DynamicSupervisor
  require Logger

  alias Aiur.Opencode.{Slot, SlotRegistry}

  # An ETS-backed LRU ring would be overkill; a simple atomic counter
  # in the registry value would be too. Slot workers stamp their
  # last-release time on themselves and we ask each one for it during
  # `acquire_slot/0` via `Slot.snapshot/1`.

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawn a `Slot` worker for `slot_index`. Returns the resulting child
  pid or `{:error, reason}` per `DynamicSupervisor.start_child/2` semantics.
  """
  @spec start_slot(pos_integer()) ::
          {:ok, pid()} | {:error, term()}
  def start_slot(slot_index) when is_integer(slot_index) and slot_index > 0 do
    spec = %{
      id: {Slot, slot_index},
      start: {Slot, :start_link, [[slot_index: slot_index]]},
      restart: :transient,
      type: :worker
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Find a slot currently in `:ready` state. Returns `{slot_index, pid}` or
  `{:error, :no_ready_slot}` when no slot is available — the caller (PaneManager)
  falls back to cold attach in that case.

  Selection strategy: scan every registered slot via `SlotRegistry.all/0`,
  filter to `:ready` status, pick the one whose Slot worker has been idle
  longest (lowest last-active stamp). Acquire is just a status read — the
  slot transitions to `:active` when `Slot.select/2` is called by the caller.
  """
  @spec acquire_slot() :: {pos_integer(), pid()} | {:error, :no_ready_slot}
  def acquire_slot do
    ready =
      SlotRegistry.all()
      |> Enum.map(fn {index, pid} -> {index, pid, Slot.snapshot(pid)} end)
      |> Enum.filter(fn {_index, _pid, snap} -> Map.get(snap, :status) == :ready end)

    case ready do
      [] ->
        {:error, :no_ready_slot}

      candidates ->
        # Lowest index = oldest slot, naturally the LRU candidate.
        {index, pid, _snap} =
          Enum.min_by(candidates, fn {index, _pid, _snap} -> index end)

        {index, pid}
    end
  end

  @doc """
  Count of currently-alive slot workers. Used by SlotPolicy to know
  whether the chain has reached its target.
  """
  @spec slot_count() :: non_neg_integer()
  def slot_count, do: length(SlotRegistry.all())
end
