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
  its slot index. Returns `:ok` on success, `{:error, :already_registered}`
  if a slot worker for the same index is already alive (shouldn't happen —
  SlotSupervisor never starts two children with the same slot index).
  """
  @spec register_self(slot_index()) :: :ok | {:error, :already_registered}
  def register_self(slot_index) when is_integer(slot_index) and slot_index > 0 do
    case Registry.register(@registry, slot_index, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
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
