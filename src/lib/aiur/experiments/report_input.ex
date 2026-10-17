defmodule Aiur.Experiments.ReportInput do
  @moduledoc false
  alias Aiur.Experiments.{AnalysisInput, Arms, Evidence, Journal, Paths, Reader, Snapshot}

  @spec prepare(String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(id) do
    with {:ok, spec, false} <- Reader.spec(id),
         {:ok, annotations} <- Journal.read(Paths.file(id, "annotations.ndjson")),
         {:ok, windows} <- frozen_windows(id, spec) do
      arms = Arms.assign(spec, Enum.map(windows, fn {name, snapshot} -> {name, %{source: :frozen, metrics: snapshot["metrics"]}} end))
      input = AnalysisInput.build(spec, annotations, arms)
      hashes = Map.new(windows, fn {name, snapshot} -> {name, snapshot["sha256"]} end)
      input = Map.put(input, "frozen_snapshots", hashes) |> Map.delete("input_sha256")
      {:ok, %{id: id, spec: spec, annotations: annotations, input: Map.put(input, "input_sha256", Evidence.hash(input)), snapshots: hashes}}
    else
      {:ok, _spec, true} -> {:error, :store_read_only}
      error -> error
    end
  end

  @spec unchanged(map()) :: :ok | {:error, term()}
  def unchanged(prepared) do
    with {:ok, current} <- prepare(prepared.id) do
      if current.input == prepared.input, do: :ok, else: {:error, :stale_preparation}
    end
  end

  defp frozen_windows(id, spec) do
    spec["windows"]
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case Snapshot.latest(id, name) do
        {:ok, nil} -> {:halt, {:error, [%{path: "snapshots.#{name}", message: "freeze this window before requesting statistics"}]}}
        {:ok, snapshot} -> {:cont, {:ok, [{name, snapshot} | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
