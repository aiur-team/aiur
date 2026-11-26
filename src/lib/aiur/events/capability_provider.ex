defmodule Aiur.Events.CapabilityProvider do
  @moduledoc "External event feed availability and configured retention."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider
  alias Aiur.Events.Export
  alias Aiur.Events.Export.Exporter

  @impl true
  def capability_ids, do: ["events.export"]

  @impl true
  def capabilities(context), do: %{"events.export" => capability(context)}

  defp capability(%{settings: %{events: %{export: %{enabled: false}}}}), do: %{state: :unavailable, reason: :disabled}

  defp capability(%{settings: %{events: %{export: %{enabled: true} = config}}, run_shape: %{http_listener: listener?}}) do
    if listener? and Process.whereis(Exporter) != nil do
      from_status(Export.status(), config)
    else
      %{state: :unavailable, reason: :not_running}
    end
  end

  defp capability(_), do: %{state: :unknown, reason: :unknown}

  defp from_status(%{state: :available, head_seq: head}, config) do
    %{
      state: :available,
      version: 1,
      v: 1,
      retention: %{max_age_s: config.retention_days * 86_400, max_records: config.retention_max_events},
      head_seq: head
    }
  end

  defp from_status(%{reason: :journal_corrupt}, _), do: %{state: :degraded, reason: :journal_corrupt}
  defp from_status(%{reason: :identity_unavailable}, _), do: Provider.dependency("identity")
  defp from_status(_status, _), do: %{state: :unknown, reason: :unknown}
end
