defmodule Aiur.Opencode.SlotRegistry do
  @moduledoc """
  Slot-keyed Registry. Resolves `slot_index :: 1..S` to the pid of the
  `Aiur.Opencode.Slot` worker that owns that slot.

  Mirrors `Aiur.Opencode.SessionWriterRegistry`: a wrapper module over
  Elixir's `Registry` (`keys: :unique`) so callers don't poke the
  Registry name directly. The Registry itself is started by
  `Aiur.Application` so the registry exists even when pre-warm is
  disabled — slot lookups must not race the supervisor tree.

  Slot workers register themselves in `Slot.init/1` via
  `register_self/1`. Lookup is a constant-time ETS read.
  """

  @registry __MODULE__.Registry

  @type slot_index :: pos_integer()

  @doc """
  The Registry name. Wired into `Aiur.Application` as a `:unique`
  Registry child.
  """
  @spec registry_name() :: module()
  def registry_name, do: @registry

  @doc """
  Slot worker calls this from its `init/1` to register its pid against
  its slot index. The registry value is a map tracking the slot's
  currently visible identifier and pane id — lock-free for any reader
  via `find_visible/1` and `pane_state/1`, so the warm-open hot path
  never has to wait on Slot's GenServer mailbox.

  Returns `:ok` on success, `{:error, :already_registered}` if a slot
  worker for the same index is already alive (shouldn't happen —
  SlotSupervisor never starts two children with the same slot index).
  """
  @spec register_self(slot_index()) :: :ok | {:error, :already_registered}
  def register_self(slot_index) when is_integer(slot_index) and slot_index > 0 do
    case Registry.register(@registry, slot_index, %{visible_identifier: nil, pane_id: nil}) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @doc """
  Slot worker calls this whenever its visible identifier or pane id
  changes. Must run from inside the slot's own process — Registry
  enforces this. Lock-free ETS write.
  """
  @spec update_pane_state(slot_index(), String.t() | nil, String.t() | nil) :: :ok
  def update_pane_state(slot_index, visible_identifier, pane_id)
      when is_integer(slot_index) and slot_index > 0 do
    Registry.update_value(@registry, slot_index, fn _ ->
      %{visible_identifier: visible_identifier, pane_id: pane_id}
    end)

    :ok
  end

  @doc """
  Read the cached `%{visible_identifier, pane_id}` for `slot_index`.
  Lock-free ETS read — does NOT call into the slot worker.
  """
  @spec pane_state(slot_index()) ::
          {:ok, %{visible_identifier: String.t() | nil, pane_id: String.t() | nil}}
          | :not_found
  def pane_state(slot_index) when is_integer(slot_index) and slot_index > 0 do
    case Registry.lookup(@registry, slot_index) do
      [{_pid, value}] when is_map(value) -> {:ok, value}
      _ -> :not_found
    end
  end

  @doc """
  Inverse lookup: find the (slot_index, pane_id) where the slot is
  currently visible for `identifier`. Returns `:not_found` when no
  slot has it painted as its current visible identifier. Lock-free
  ETS scan over the (small) slot set.
  """
  @spec find_visible(String.t()) ::
          {:ok, slot_index(), String.t()} | :not_found
  def find_visible(identifier) when is_binary(identifier) do
    @registry
    |> Registry.select([{{:"$1", :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.find_value(:not_found, fn
      {slot_index, %{visible_identifier: ^identifier, pane_id: pane_id}}
      when is_binary(pane_id) ->
        {:ok, slot_index, pane_id}

      _ ->
        nil
    end)
  end

  @doc """
  Look up the slot worker pid for `slot_index`. Returns `{:ok, pid}` if
  found and alive, `:not_found` otherwise.
  """
  @spec lookup(slot_index()) :: {:ok, pid()} | :not_found
  def lookup(slot_index) when is_integer(slot_index) and slot_index > 0 do
    case Registry.lookup(@registry, slot_index) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :not_found

      _ ->
        :not_found
    end
  end

  @doc """
  Enumerate every (slot_index, pid) currently registered. Used by
  `SlotSupervisor.acquire_slot/0` and diagnostics.
  """
  @spec all() :: [{slot_index(), pid()}]
  def all do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_index, pid} -> Process.alive?(pid) end)
  end
end
