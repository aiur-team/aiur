defmodule Aiur.CommandsCLI.Repair do
  @moduledoc "`aiur commands repair`: quarantine unverifiable Decision journal records and restore writes (#7577)."

  alias Aiur.Commands

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case Keyword.get(opts, :repair_fun, &Commands.repair_journal/0).() do
      {:ok, report} ->
        if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(json(report))), else: print(report)
        if report.health == :writable, do: 0, else: 1

      {:error, reason} ->
        IO.puts(:stderr, "aiur: commands repair failed: #{inspect(reason)}")
        1
    end
  end

  defp json(report) do
    %{
      kept: report.kept,
      quarantine_path: report.quarantine_path,
      quarantined: Enum.map(report.quarantined, &%{line: &1.line, reason: inspect(&1.reason)}),
      health: inspect(report.health)
    }
  end

  defp print(%{quarantined: []} = report) do
    IO.puts("Decision journal verified: #{report.kept} records, nothing quarantined. Store health: #{inspect(report.health)}.")
  end

  defp print(report) do
    IO.puts("Quarantined #{length(report.quarantined)} record(s) to #{report.quarantine_path}:")
    Enum.each(report.quarantined, &IO.puts("  line #{&1.line}: #{inspect(&1.reason)}"))
    IO.puts("Kept #{report.kept} record(s). Store health: #{inspect(report.health)}.")
  end
end
