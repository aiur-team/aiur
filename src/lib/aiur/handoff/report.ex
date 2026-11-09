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

  @doc "Per-project latest reports (each read in its project's context); one report when there are no projects."
  @spec latest_all(keyword()) :: {:ok, map()} | :none | {:error, term()}
  def latest_all(opts \\ []) do
    case Aiur.Project.Registry.project_ids() do
      [] ->
        latest(opts)

      projects ->
        reports =
          for id <- projects do
            Task.async(fn ->
              Aiur.Project.Context.put(Aiur.Project.Registry.project(id))
              latest(opts)
            end)
          end
          |> Task.await_many(10_000)

        case for({:ok, r} <- reports, do: r) do
          [] -> Enum.find(reports, :none, &match?({:error, _}, &1))
          oks -> {:ok, merge(oks)}
        end
    end
  end

  defp merge(reports) do
    %{
      handoff_id: Enum.map_join(reports, ",", & &1.handoff_id),
      written_at: reports |> Enum.map(& &1.written_at) |> Enum.min(),
      completed_at: reports |> Enum.map(& &1.completed_at) |> Enum.max(),
      gap_ms: reports |> Enum.map(& &1.gap_ms) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
      adopted: Enum.flat_map(reports, & &1.adopted),
      fallback: Enum.flat_map(reports, & &1.fallback)
    }
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
