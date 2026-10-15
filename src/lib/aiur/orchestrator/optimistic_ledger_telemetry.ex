defmodule Aiur.Orchestrator.OptimisticLedgerTelemetry do
  @moduledoc "Lifecycle points for persisted optimistic attempt transitions."
  alias Aiur.RunTelemetry.Lifecycle

  @spec record_changes(map(), map()) :: :ok
  def record_changes(previous, current) do
    Enum.each(current, fn {id, row} ->
      case Map.get(previous, id) do
        %{"v" => 1} = old -> record_transition(old, row)
        _ -> :ok
      end
    end)

    record_outcomes(previous, current)
    :ok
  end

  defp record_transition(old, row) do
    record_evidence(old, row)

    cond do
      row["status"] == "parked" and old["status"] != "parked" ->
        blocker = Enum.find(row["blockers"], &(&1["park_cause"] != nil)) || %{}
        emit(row, :optimistic_park, %{blocker: blocker["id"], cause: blocker["park_cause"]}, row["status_changed_at_ms"])

      row["status"] == "running" and old["status"] == "parked" ->
        emit(row, :optimistic_resume, %{}, row["status_changed_at_ms"])

      true ->
        :ok
    end
  end

  defp record_outcomes(previous, current) do
    changed = Enum.filter(Map.values(current), fn row -> row["v"] == 1 and row["status"] == "closed" and get_in(previous, [row["attempt_id"], "outcome"]) != row["outcome"] end)

    for {ticket, rows} <- Enum.group_by(changed, & &1["ticket"]) do
      attempts = Enum.filter(Map.values(current), &(&1["ticket"] == ticket))
      row = Enum.max_by(rows, &{&1["attempt_sequence"] || 0, &1["started_at_ms"]})
      first = Enum.min_by(attempts, & &1["started_at_ms"])
      redo? = Enum.any?(attempts, &(&1["counters"]["parks"] > 0))
      outcome = if row["outcome"] == "merged" and redo?, do: "merged_after_redo", else: row["outcome"]
      evidence = %{first | "outcome" => outcome}
      emit(row, :optimistic_outcome, %{outcome: outcome, operation_id: outcome, start_trigger: first["start_trigger"], head_start_ms: head_start(evidence)}, row["closed_at_ms"])
    end
  end

  defp record_evidence(old, row) do
    for evidence <- Map.get(row, "observed_pushes", []) -- Map.get(old, "observed_pushes", []) do
      Lifecycle.record(row["ticket"], row["attempt_id"], :blocker_push, :point, %{blocker: evidence["blocker"], source_id: "push:#{evidence["blocker"]}:#{evidence["sha"]}"})
    end

    for evidence <- Map.get(row, "integration_reports", []) -- Map.get(old, "integration_reports", []) do
      Lifecycle.record(row["ticket"], row["attempt_id"], :blocker_integrate, :point, %{
        blocker: evidence["blocker"],
        outcome: if(evidence["conflict"], do: :conflict, else: :clean),
        non_ff: evidence["non_ff"],
        operation_id: "#{if(evidence["conflict"], do: "conflict", else: "clean")}:#{evidence["non_ff"]}",
        source_id: "integration:#{evidence["blocker"]}:#{evidence["sha"]}"
      })
    end
  end

  defp head_start(%{"outcome" => outcome} = row) when outcome in ["merged", "merged_after_redo"] do
    merged = Enum.map(row["blockers"], & &1["merged_at_ms"])

    if merged != [] and Enum.all?(merged, &is_integer/1),
      do: max(0, Enum.min(merged) - row["started_at_ms"]),
      else: nil
  end

  defp head_start(_row), do: nil

  defp emit(row, event, metadata, at) do
    opts = if is_integer(at), do: [timestamp: DateTime.from_unix!(at, :millisecond)], else: []
    metadata = Map.put(metadata, :source_id, "#{event}:#{at || row["status"]}")
    Lifecycle.record(row["ticket"], row["attempt_id"], event, :point, metadata, opts)
  end
end
