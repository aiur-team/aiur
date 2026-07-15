defmodule Aiur.ProviderAccountGeneration.Monitor do
  @moduledoc false

  @spec owner(map(), pid()) :: map()
  def owner(entry, owner_pid) when is_pid(owner_pid) do
    case entry.monitor do
      {_monitor, ^owner_pid} ->
        entry

      {monitor, _other_owner} ->
        Process.demonitor(monitor, [:flush])
        %{entry | monitor: {Process.monitor(owner_pid), owner_pid}}

      nil ->
        %{entry | monitor: {Process.monitor(owner_pid), owner_pid}}
    end
  end

  @spec clear(map() | nil) :: :ok
  def clear(%{monitor: {monitor, _owner_pid}}), do: Process.demonitor(monitor, [:flush])
  def clear(_entry), do: :ok
end
