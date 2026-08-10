defmodule Aiur.CurrentRunMembership.Reconciler.Snapshot do
  @moduledoc false

  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.TrackerIdentity

  @waiting_reasons [
    :waiting_for_human,
    :waiting_for_supervisor,
    :waiting_for_dependency,
    :waiting_for_ci,
    :waiting_for_review,
    :awaiting_dispatch,
    :tracker_unavailable,
    :backing_off,
    :unresponsive
  ]
  @lifecycle_values [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]

  @spec reconcile(map(), (TrackerIdentity.t(), atom() -> term()), MapSet.t()) :: [term()]
  def reconcile(snapshot, observe_fun, terminal_states)
      when is_map(snapshot) and is_function(observe_fun, 2) and is_struct(terminal_states, MapSet) do
    snapshot
    |> observation_rows()
    |> Enum.flat_map(&observe_row(&1, observe_fun, terminal_states))
  end

  defp observation_rows(snapshot) do
    rows_by_kind = [
      running: Map.get(snapshot, :running, []),
      retrying: Map.get(snapshot, :retrying, []),
      idle: Map.get(snapshot, :idle, [])
    ]

    for {kind, rows} <- rows_by_kind,
        row <- rows,
        is_map(row) do
      {kind, row}
    end
  end

  defp observe_row({kind, row}, observe_fun, terminal_states) do
    case tracker_identity(row) do
      %TrackerIdentity{} = identity -> observe_joinable(identity, kind, row, observe_fun, terminal_states)
      _ -> []
    end
  end

  defp observe_joinable(identity, kind, row, observe_fun, terminal_states) do
    if TrackerIdentity.joinable?(identity) do
      [observe_fun.(identity, lifecycle_for_row(kind, row, terminal_states))]
    else
      []
    end
  end

  @spec lifecycle_for_row(atom(), map(), MapSet.t()) :: atom()
  def lifecycle_for_row(kind, row, terminal_states) do
    explicit_lifecycle(row) ||
      terminal_lifecycle_for(row, terminal_states) ||
      replaced_lifecycle(row) ||
      paused_lifecycle(row) ||
      waiting_lifecycle(row) ||
      allocated_lifecycle(row) ||
      lifecycle_for_row_kind(kind)
  end

  defp explicit_lifecycle(row) do
    lifecycle = row_value(row, :lifecycle)
    if lifecycle in @lifecycle_values, do: lifecycle
  end

  defp terminal_lifecycle_for(row, terminal_states) do
    state = row_value(row, :state)
    if DispatchPolicy.terminal_issue_state?(state, terminal_states), do: terminal_lifecycle(state)
  end

  defp replaced_lifecycle(row) do
    if normalize_state(row_value(row, :state)) == "replaced" or row_value(row, :work_state) == :replaced do
      :replaced
    end
  end

  defp paused_lifecycle(row) do
    if tracker_paused?(row) or row_value(row, :work_state) in [:paused, :sleeping], do: :paused
  end

  defp waiting_lifecycle(row) do
    if row_value(row, :waiting_reason) in @waiting_reasons, do: :waiting
  end

  defp allocated_lifecycle(row) do
    if row_value(row, :work_state) == :allocated, do: :allocated
  end

  defp lifecycle_for_row_kind(:retrying), do: :retrying
  defp lifecycle_for_row_kind(:running), do: :running
  defp lifecycle_for_row_kind(:idle), do: :queued
  defp tracker_identity(row), do: Map.get(row, :tracker_identity) || Map.get(row, "tracker_identity")
  defp tracker_paused?(row), do: Map.get(row, :tracker_paused) == true or Map.get(row, "tracker_paused") == true
  defp row_value(row, key), do: Map.get(row, key) || Map.get(row, Atom.to_string(key))
  defp terminal_lifecycle(state), do: if(normalize_state(state) in ["cancelled", "canceled"], do: :cancelled, else: :completed)
  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
