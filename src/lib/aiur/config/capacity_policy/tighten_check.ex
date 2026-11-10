defmodule Aiur.Config.CapacityPolicy.TightenCheck do
  @moduledoc "Refuses a project `capacity` value that loosens the machine policy in `~/.aiur/machine`."
  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.Config.CapacityPolicy
  alias Aiur.Machine.Settings

  @impl true
  def applies?(_settings), do: true

  @impl true
  def check(%{capacity: %{sources: sources, limits: limits}}) when sources == %{} and limits == %{}, do: :ok

  def check(%{capacity: capacity}) do
    case Settings.get() do
      {:ok, machine} -> CapacityPolicy.tightens(machine.capacity, capacity, "L3")
      {:error, reason} -> {:error, {:invalid_workflow_config, "capacity: machine settings are unreadable (#{inspect(reason)})"}}
    end
  end
end
