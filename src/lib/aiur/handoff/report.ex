defmodule Aiur.Handoff.Report do
  @moduledoc "Durable restart outcomes for operator verification."
  alias Aiur.Handoff.Record

  @spec provider_pid(term()) :: String.t() | nil
  def provider_pid(pid) when is_integer(pid) and pid > 0, do: Integer.to_string(pid)
  def provider_pid(pid) when is_binary(pid), do: pid
  def provider_pid(_pid), do: nil

  @spec latest(keyword()) :: {:ok, map()} | :none | {:error, term()}
  def latest(opts \\ []) do
    case Aiur.JsonStore.read(Record.path(opts) <> ".consumed") do
      {:ok, %{"completed_at" => completed_at} = record} when is_binary(completed_at) -> {:ok, from_record(record)}
      {:ok, _record} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec from_record(map()) :: map()
  def from_record(record) do
    outcomes = record["outcome"] || []

    %{
      handoff_id: record["handoff_id"],
      written_at: record["written_at"],
      completed_at: record["completed_at"],
      gap_ms: gap(record["written_at"], record["completed_at"]),
      adopted: Enum.filter(outcomes, &(&1["status"] == "adopted")),
      fallback: Enum.filter(outcomes, &(&1["status"] == "fallback"))
    }
  end

  @spec notify(keyword()) :: :ok
  def notify(opts \\ []) do
    emit = Keyword.get(opts, :emit_alert, &Aiur.Alerts.emit_system/2)

    with {:ok, report} <- latest(opts) do
      emit.("system.restart.handoff.completed",
        message: "Handoff #{report.handoff_id}: #{length(report.adopted)} adopted, #{length(report.fallback)} fallback; gap=#{report.gap_ms}ms",
        reason: "Restart adoption report is available with aiur status --handoff --json.",
        needs_attention: false,
        severity: "info",
        central: true
      )

      if report.fallback != [] do
        reasons = Enum.map_join(report.fallback, ", ", &"#{&1["identifier"]}: #{&1["reason"]}")

        emit.("system.restart.handoff.fallback",
          message: "Handoff #{report.handoff_id} fallback: #{reasons}",
          reason: "These agents require ordinary session resume.",
          needs_attention: true,
          severity: "warning",
          central: true
        )
      end
    end

    :ok
  end

  defp gap(started, completed) when is_binary(started) and is_binary(completed) do
    with {:ok, from, _} <- DateTime.from_iso8601(started),
         {:ok, to, _} <- DateTime.from_iso8601(completed) do
      max(0, DateTime.diff(to, from, :millisecond))
    else
      _ -> nil
    end
  end

  defp gap(_, _), do: nil
end
