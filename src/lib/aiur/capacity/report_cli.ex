defmodule Aiur.Capacity.ReportCLI do
  @moduledoc "`aiur capacity report --since <date>`: reads every retained run's capacity samples and dispatch points."

  alias Aiur.Capacity.{Report, SampleLog}
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec rpc(String.t(), boolean()) :: :ok
  def rpc(since, json), do: guarded("capacity", fn -> exit_marker(run(since, json)) end)

  @doc "Prints the report; `:logs_root` overrides the retained run-log root. Returns the exit code."
  @spec run(String.t(), boolean(), keyword()) :: 0 | 64
  def run(since, json, opts \\ []) do
    case parse_since(since) do
      {:ok, since} ->
        root = Keyword.get_lazy(opts, :logs_root, &logs_root/0)
        report = Report.build(read(root, "capacity.ndjson", ""), read(root, "telemetry.ndjson*", "\"dispatch\""), since)
        IO.puts(if json, do: Jason.encode!(report), else: Report.render(report))
        0

      :error ->
        IO.puts(:stderr, "aiur: capacity report --since takes a date (2026-11-01) or an ISO 8601 time")
        64
    end
  end

  @doc false
  @spec parse_since(String.t()) :: {:ok, DateTime.t()} | :error
  def parse_since(value) do
    case {DateTime.from_iso8601(value), Date.from_iso8601(value)} do
      {{:ok, at, _offset}, _date} -> {:ok, at}
      {_time, {:ok, date}} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      _neither -> :error
    end
  end

  # Same retained root as `Aiur.RunTelemetry.Summaries`: `<root>/<run>/log/`.
  defp logs_root do
    directory = SampleLog.path() |> Path.expand() |> Path.dirname()
    if Path.basename(directory) == "log", do: directory |> Path.dirname() |> Path.dirname(), else: directory
  end

  # A line that does not decode is skipped: one torn append must not hide a week.
  defp read(root, name, needle) do
    Path.join([root, "*", "log", name])
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".gz"))
    |> Enum.flat_map(fn path ->
      path
      |> File.stream!()
      |> Stream.filter(&String.contains?(&1, needle))
      |> Enum.flat_map(&decode/1)
    end)
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _other -> []
    end
  end
end
