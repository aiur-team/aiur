defmodule Aiur.Experiments.AnalysisInput do
  @moduledoc "Exports the stable, flat evidence consumed by experiment analysis."

  alias Aiur.Experiments.{Arms, Evidence, Journal, Paths, Persistence, Reader}

  @spec export(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(id, opts \\ []) do
    with :ok <- Persistence.writable(id),
         {:ok, spec, false} <- Reader.spec(id),
         {:ok, annotations} <- Journal.read(Paths.file(id, "annotations.ndjson")),
         {:ok, arms} <- Arms.read(id, opts),
         input = build(spec, annotations, arms),
         :ok <- Persistence.write_json(Paths.file(id, "report/analysis-input.json"), input) do
      {:ok, input}
    else
      {:ok, _spec, true} -> {:error, :newer_spec}
      error -> error
    end
  end

  @spec build(map(), [map()], map()) :: map()
  def build(spec, annotations, arms) do
    rows =
      for {group, arm} <- arms["arms"],
          {metric, evidence} <- arm["metrics"],
          row <- evidence["observations"] do
        %{
          "metric" => metric,
          "unit_id" => row["unit_id"],
          "group" => group,
          "value" => row["value"],
          "censored" => row["censored"] || false,
          "strata" => strata(row["attrs"] || %{}, spec["stratify_by"]),
          "observed_at" => row["at"]
        }
      end

    input = %{
      "schema_version" => "aiur.experiment-analysis-input/v1",
      "spec" => spec,
      "registered_at" => spec["registered_at"],
      "annotations" => annotations,
      "rows" => Enum.sort_by(rows, &{&1["metric"], &1["group"], &1["unit_id"], &1["observed_at"]})
    }

    Map.put(input, "input_sha256", Evidence.hash(input))
  end

  defp strata(attrs, fields) do
    Map.new(fields, fn field ->
      value =
        Enum.reduce(String.split(field, "."), attrs, fn
          key, value when is_map(value) -> value[key]
          _key, _value -> nil
        end)

      {field, value}
    end)
  end
end
