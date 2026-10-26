defmodule Aiur.Experiments.WindowEvents.Telemetry do
  @moduledoc false
  alias Aiur.Experiments.Sources.Common
  alias Aiur.Experiments.TelemetryReader
  alias Aiur.RunTelemetry.Summaries

  @attributes %{
    "restart" => ~w(event daemon_started_at),
    "run_context" => ~w(aiur_vsn config_hash config_section_hashes),
    "resource" => ~w(actor fleet_agents_max fleet_agents_effective)
  }

  @spec read(keyword()) :: {[map()], [String.t()]}
  def read(opts) do
    window = %{start: Common.timestamp(opts[:range_start]), end: Common.timestamp(opts[:range_end])}
    options = Keyword.get(opts, :telemetry_reader_options, []) |> Keyword.put(:keep_kinds, ~w(restart run_context resource)) |> Keyword.put(:attribute_keys, @attributes)
    {:ok, result} = TelemetryReader.read(window, Keyword.get_lazy(opts, :telemetry_sources, &sources/0), options)

    rows =
      result.records
      |> Enum.map(fn row ->
        %{"kind" => row.kind, "timestamp" => row.timestamp_iso, "boot_id" => row.boot_id, "record_id" => row.record_id, "attributes" => row.attributes}
      end)
      |> Enum.uniq_by(&{&1["boot_id"], &1["record_id"], &1["kind"], &1["timestamp"], &1["attributes"]})

    {rows, if(result.state != :complete or rows == [], do: ["telemetry"], else: [])}
  end

  # Retained boots have no range index; unknown bounds stay eligible within the shared read budget.
  defp sources do
    [%{path: Aiur.RunTelemetry.telemetry_file(), format: :ndjson}] ++
      Enum.map(Summaries.summary_boot_ids(), &%{path: Summaries.run_summary_path(&1), format: :summary})
  end
end
