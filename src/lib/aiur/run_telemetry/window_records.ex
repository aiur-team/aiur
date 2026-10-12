defmodule Aiur.RunTelemetry.WindowRecords do
  @moduledoc false
  alias Aiur.RunTelemetry.Summaries

  @spec read(keyword()) :: {[map()], [String.t()]}
  def read(opts) do
    files = Keyword.get_lazy(opts, :telemetry_files, fn -> [Aiur.RunTelemetry.telemetry_file()] end)
    summaries = Keyword.get_lazy(opts, :summary_files, fn -> Path.wildcard(Path.join(Summaries.runs_dir(), "*/run-summary.json")) end)
    {rows, missing} = Enum.reduce(files, {[], []}, &read_stream/2)
    {rows, missing} = Enum.reduce(summaries, {rows, missing}, &read_summary/2)
    valid = Enum.filter(rows, &valid_record?/1)
    missing = if length(valid) != length(rows), do: ["telemetry" | missing], else: missing
    rows = Enum.uniq_by(valid, &{&1["boot_id"], &1["record_id"], &1["kind"], &1["timestamp"], &1["attributes"]})
    {rows, if(rows == [], do: ["telemetry" | missing], else: Enum.uniq(missing))}
  end

  defp valid_record?(row) do
    is_map(row) and is_map(row["attributes"]) and is_binary(row["boot_id"]) and
      is_binary(row["timestamp"]) and match?({:ok, _, _}, DateTime.from_iso8601(row["timestamp"]))
  end

  defp read_stream(path, {rows, missing}) do
    parsed = path |> File.stream!() |> Enum.map(&Jason.decode/1)
    good = for {:ok, row} <- parsed, is_map(row), do: row
    {good ++ rows, if(length(good) == length(parsed), do: missing, else: ["telemetry" | missing])}
  rescue
    _error -> {rows, ["telemetry" | missing]}
  end

  defp read_summary(path, {rows, missing}) do
    with {:ok, body} <- File.read(path), {:ok, %{"records" => records} = summary} when is_list(records) <- Jason.decode(body) do
      {records ++ Map.get(summary, "restarts", []) ++ rows, missing}
    else
      _error -> {rows, ["telemetry" | missing]}
    end
  end
end
