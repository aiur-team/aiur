defmodule Aiur.Experiments.ReportReads do
  @moduledoc false
  alias Aiur.Experiments
  alias Aiur.Experiments.ReportRecords

  @spec detail(String.t(), {:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def detail(id, {:ok, detail}) do
    post? = not detail.read_only? and Enum.any?(detail.snapshots, &post_snapshot?/1)
    with :ok <- record(id, post?), {:ok, records} <- ReportRecords.read(id), do: {:ok, Map.put(detail, :report_records, records)}
  end

  def detail(_id, error), do: error

  @spec arms(String.t(), {:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def arms(id, {:ok, data}) do
    outcomes? = Enum.any?(data["arms"] || %{}, fn {group, arm} -> group != "before" and metrics?(arm["metrics"]) end)
    with :ok <- record(id, outcomes?), do: {:ok, data}
  end

  def arms(_id, error), do: error

  @spec input(String.t(), {:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def input(id, {:ok, data}) do
    with :ok <- record(id, Enum.any?(data["rows"], &(&1["group"] != "before"))), do: {:ok, data}
  end

  def input(_id, error), do: error

  @spec snapshot(String.t(), {:ok, map()} | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def snapshot(id, {:ok, data}) do
    with :ok <- record(id, post_snapshot?(data)), do: {:ok, data}
  end

  def snapshot(_id, error), do: error
  defp post_snapshot?(snapshot), do: snapshot["window_name"] != "before" and metrics?(snapshot["metrics"])
  defp metrics?(metrics), do: Enum.any?(metrics || %{}, fn {_metric, row} -> (row["n"] || get_in(row, ["summary", "n"]) || 0) > 0 end)
  defp record(id, true), do: Experiments.record_results_read(id)
  defp record(_id, false), do: :ok
end
