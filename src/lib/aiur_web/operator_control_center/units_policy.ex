defmodule AiurWeb.OperatorControlCenter.UnitsPolicy do
  @moduledoc """
  The renderer-independent truth table for the Units catalog.

  A row can match more than one condition. Scope chooses the candidate set;
  selected conditions then refine it with OR semantics.
  """

  @scopes [:live, :unfinished, :all, :none]
  @conditions [:active, :alert, :paused, :stuck, :queued, :finished]
  @queue_reasons [:awaiting_dispatch, :waiting_for_dependency, :backing_off]
  @stuck_reasons [:backing_off, :unresponsive]

  @type scope :: :live | :unfinished | :all | :none
  @type condition :: :active | :alert | :paused | :stuck | :queued | :finished
  @type selection :: %{scope: scope(), conditions: [condition()]}

  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @spec conditions() :: [condition()]
  def conditions, do: @conditions

  @spec default_selection() :: selection()
  def default_selection, do: %{scope: :live, conditions: []}

  @spec normalize_selection(term()) :: selection()
  def normalize_selection(selection) when is_map(selection) do
    %{
      scope: normalize_scope(Map.get(selection, :scope) || Map.get(selection, "scope")),
      conditions: normalize_conditions(Map.get(selection, :conditions) || Map.get(selection, "conditions"))
    }
  end

  def normalize_selection(_selection), do: default_selection()

  @spec scope(selection()) :: scope()
  def scope(selection), do: selection.scope

  @spec selected?(selection(), condition()) :: boolean()
  def selected?(selection, condition), do: condition in selection.conditions

  @spec rows_for_scope([map()], scope() | selection() | term()) :: [map()]
  def rows_for_scope(rows, selection) when is_list(rows) do
    scope = if selection in @scopes, do: selection, else: selection |> normalize_selection() |> Map.fetch!(:scope)
    Enum.filter(rows, &in_scope?(&1, scope))
  end

  def rows_for_scope(_rows, _selection), do: []

  @spec filter([map()], selection() | term()) :: [map()]
  def filter(rows, selection) when is_list(rows) do
    selection = normalize_selection(selection)
    scoped_rows = rows_for_scope(rows, selection)

    if selection.conditions == [] do
      scoped_rows
    else
      Enum.filter(scoped_rows, fn row -> Enum.any?(selection.conditions, &condition?(&1, row)) end)
    end
  end

  def filter(_rows, _selection), do: []

  @doc "Counts condition chips over the selected scope before condition refinement."
  @spec counts([map()], selection() | term()) :: %{optional(condition()) => non_neg_integer(), scope: non_neg_integer()}
  def counts(rows, selection) when is_list(rows) do
    scoped_rows = rows_for_scope(rows, selection)

    @conditions
    |> Map.new(fn condition -> {condition, Enum.count(scoped_rows, &condition?(condition, &1))} end)
    |> Map.put(:scope, length(scoped_rows))
  end

  def counts(_rows, _selection), do: counts([], default_selection())

  @spec in_scope?(map(), scope()) :: boolean()
  def in_scope?(row, :live) when is_map(row), do: live?(row)
  def in_scope?(row, :unfinished) when is_map(row), do: unfinished?(row)
  def in_scope?(row, :all) when is_map(row), do: true
  def in_scope?(_row, :none), do: false
  def in_scope?(_row, _scope), do: false

  @spec condition?(condition() | term(), map()) :: boolean()
  def condition?(:active, row) when is_map(row), do: active?(row)
  def condition?(:alert, row) when is_map(row), do: alert?(row)
  def condition?(:paused, row) when is_map(row), do: paused?(row)
  def condition?(:stuck, row) when is_map(row), do: stuck?(row)
  def condition?(:queued, row) when is_map(row), do: queued?(row)
  def condition?(:finished, row) when is_map(row), do: finished?(row)
  def condition?(_condition, _row), do: false

  defp live?(row), do: runtime_bucket(row) == :running and not replacement_boundary?(row)

  defp unfinished?(row), do: not finished?(row) and (live?(row) or queued?(row))

  defp active?(row), do: live?(row) and work_state(row) in [:allocated, :working]

  defp alert?(row) do
    present?(reason(row, :alert)) or open_command_count(row) > 0
  end

  defp paused?(row) do
    Map.get(row, :tracker_paused?) == true or
      get_in(row, [:runtime, :tracker_paused?]) == true or
      present?(reason(row, :pause)) or
      work_state(row) in [:paused, :sleeping]
  end

  defp stuck?(row), do: reason(row, :stuck) in @stuck_reasons or waiting_reason(row) in @stuck_reasons

  defp queued?(row) do
    not finished?(row) and
      (Map.get(row, :lifecycle) in [:queued, :retrying, :waiting] or
         runtime_bucket(row) == :retrying or
         waiting_reason(row) in @queue_reasons or
         replacement_boundary?(row))
  end

  defp finished?(row), do: Map.get(row, :terminal?) == true and not replacement_boundary?(row)

  defp replacement_boundary?(row), do: Map.get(row, :replacement_boundary?) == true

  defp runtime_bucket(row), do: get_in(row, [:runtime, :bucket]) || Map.get(row, :runtime_bucket)
  defp work_state(row), do: get_in(row, [:runtime, :work_state]) || Map.get(row, :work_state)
  defp waiting_reason(row), do: reason(row, :waiting)

  defp reason(row, name) do
    direct =
      case name do
        :alert -> Map.get(row, :alert_reason)
        :pause -> Map.get(row, :pause_reason)
        :stuck -> Map.get(row, :stuck_reason)
        :waiting -> Map.get(row, :waiting_reason)
      end

    get_in(row, [:reasons, name]) || direct || if(name == :waiting, do: get_in(row, [:runtime, :waiting_reason]))
  end

  defp open_command_count(row) do
    case Map.get(row, :open_command_count) || Map.get(row, :open_decision_count) do
      count when is_integer(count) and count > 0 -> count
      _count -> 0
    end
  end

  defp normalize_scope(scope) when scope in @scopes, do: scope

  defp normalize_scope(scope) when is_binary(scope) do
    Enum.find(@scopes, :live, &(Atom.to_string(&1) == String.downcase(String.trim(scope))))
  end

  defp normalize_scope(_scope), do: :live

  defp normalize_conditions(%MapSet{} = conditions) do
    conditions
    |> MapSet.to_list()
    |> normalize_conditions()
  end

  defp normalize_conditions(conditions) when is_list(conditions) do
    normalized =
      conditions
      |> Enum.map(&normalize_condition/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.filter(@conditions, &(&1 in normalized))
  end

  defp normalize_conditions(conditions) when is_binary(conditions) do
    conditions |> String.split(",", trim: true) |> normalize_conditions()
  end

  defp normalize_conditions(_conditions), do: []

  defp normalize_condition(condition) when condition in @conditions, do: condition

  defp normalize_condition(condition) when is_binary(condition) do
    Enum.find(@conditions, &(Atom.to_string(&1) == String.downcase(String.trim(condition))))
  end

  defp normalize_condition(_condition), do: nil

  defp present?(value), do: not is_nil(value) and value != false and value != ""
end
