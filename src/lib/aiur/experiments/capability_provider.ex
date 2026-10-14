defmodule Aiur.Experiments.CapabilityProvider do
  @moduledoc "Experiment store availability for clients."
  @behaviour Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["experiments", "experiments.metric_packs"]

  @impl true
  def capabilities(context) do
    status = Map.get(context, :experiments_status, &Aiur.Experiments.status/0).()
    catalog = Map.get(context, :experiments_catalog, &Aiur.Experiments.metric_catalog/0).()
    %{"experiments" => capability(status), "experiments.metric_packs" => packs_capability(status, catalog)}
  rescue
    _error -> unknown()
  catch
    :exit, _reason -> unknown()
  end

  defp packs_capability(%{store: {:error, :disabled}}, _catalog), do: %{state: :unavailable, reason: :disabled}
  defp packs_capability(_status, %{problems: [_ | _]}), do: %{state: :degraded, reason: :pack_invalid}
  defp packs_capability(_status, %{problems: []}), do: %{state: :available}
  defp packs_capability(_status, _catalog), do: %{state: :unknown, reason: :unknown}

  defp capability(%{available?: true, store: :ok}), do: %{state: :available}
  defp capability(%{store: {:error, :disabled}}), do: %{state: :unavailable, reason: :disabled}
  defp capability(%{store: {:error, :store_read_only}}), do: %{state: :degraded, reason: :store_read_only}
  defp capability(%{store: {:error, _reason}}), do: %{state: :unavailable, reason: :store_unavailable}
  defp capability(_status), do: %{state: :unknown, reason: :unknown}
  defp unknown, do: Map.new(capability_ids(), &{&1, %{state: :unknown, reason: :unknown}})
end
