defmodule Aiur.Capabilities do
  @moduledoc "Read-only instance capability reports with per-boot revisions and read-time freshness."

  alias Aiur.Capabilities.{Collector, Monitor}

  @min_client_versions %{}

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    table = Keyword.get(opts, :table, :aiur_capabilities)
    now = Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end)
    {report, computed_at, missing?} = stored_report(table, opts, now)
    age = max(0, now.() - computed_at)

    Map.merge(report, %{
      contract: "aiur.capabilities",
      contract_version: 1,
      boot_id: Aiur.Boot.run_id(),
      min_client_versions: @min_client_versions,
      age_ms: age,
      freshness: if(missing? or age > 6_000, do: "stale", else: "current")
    })
  end

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(Monitor, :refresh)

  @doc "Converts a report to the public v1 wire shape, excluding provider diagnostics."
  @spec to_wire(map()) :: map()
  def to_wire(report) do
    report
    |> Map.take(~w(contract contract_version boot_id revision observed_at age_ms freshness min_client_versions)a)
    |> Map.merge(%{
      machine: section(report[:machine], ~w(machine_id label)a),
      instance: section(report[:instance], ~w(instance_id aiur_version run_shape)a),
      repository: section(report[:repository], ~w(kind owner name)a),
      executor: section(report[:executor], ~w(state consumer_id harness session_ref)a),
      capabilities:
        Map.new(report.capabilities, fn {id, entry} ->
          {id, Map.take(entry, ~w(state reason depends_on version observed_at route mode v retention)a)}
        end)
    })
    |> Aiur.JSONSafe.normalize()
  end

  defp section(nil, _keys), do: nil
  defp section(value, keys), do: Map.take(value, keys)

  defp stored_report(table, opts, now) do
    case :ets.lookup(table, :report) do
      [{:report, {report, computed_at, _digest}}] -> {report, computed_at, false}
      [] -> fallback(opts, now, false)
    end
  rescue
    ArgumentError -> fallback(opts, now, true)
  end

  defp fallback(opts, now, missing?) do
    {report, _warnings} = Collector.collect(opts)
    report = Map.merge(report, %{revision: 0, observed_at: DateTime.utc_now() |> DateTime.to_iso8601()})
    {report, now.(), missing?}
  end
end
