defmodule AiurWeb.OperatorControlCenter.UnitsRow.Fields do
  @moduledoc false

  alias AiurWeb.OperatorControlCenter.UnitsRow.Value

  @blocking_reasons [
    :waiting_for_human,
    :waiting_for_supervisor,
    :waiting_for_dependency,
    :waiting_for_ci,
    :waiting_for_review
  ]

  @spec replacement_boundary?(map() | term()) :: boolean()
  def replacement_boundary?(status_row) do
    Value.get(status_row, :work_state) == :completed
  end

  @spec sourced_value(map() | term(), map() | term(), [atom()]) :: {term(), atom()}
  def sourced_value(issue_fact, status_row, keys) do
    [{:canonical_issue, issue_fact}, {:status_report, status_row}]
    |> Enum.find_value({nil, :unknown}, &source_value(&1, keys))
  end

  @spec sourced_complexity(map() | term(), map() | term()) :: {term(), atom()}
  def sourced_complexity(issue_fact, status_row) do
    sourced_derived_value(issue_fact, status_row, &complexity/1)
  end

  @spec sourced_build_lane(map() | term(), map() | term()) :: {term(), atom()}
  def sourced_build_lane(issue_fact, status_row) do
    sourced_derived_value(issue_fact, status_row, &build_lane/1)
  end

  @spec reasons(map() | term(), map() | term()) :: map()
  def reasons(status_row, decision_row) do
    waiting = Value.get(status_row, :waiting_reason)
    pause = Value.get(status_row, :pause_reason)
    explicit_alert = Value.get(status_row, :alert_reason)
    count = decision_count(decision_row, status_row)

    %{
      waiting: waiting,
      blocking: blocking_reason(status_row, waiting),
      alert: alert_reason(explicit_alert, count),
      pause: pause_reason(status_row, pause),
      stuck: stuck_reason(status_row, waiting)
    }
  end

  @spec runtime(map() | term(), map() | term()) :: map()
  def runtime(status_row, member) do
    %{
      bucket: Value.get(status_row, :bucket),
      work_state: Value.get(status_row, :work_state),
      waiting_reason: Value.get(status_row, :waiting_reason),
      tracker_paused?: Value.get(status_row, :tracker_paused) == true,
      runtime_seconds: Value.get(status_row, :runtime_seconds),
      stale_for_seconds: Value.get(status_row, :stale_for_seconds),
      membership_lifecycle: Map.get(member, :lifecycle)
    }
  end

  @spec decision_count(map() | term(), map() | term()) :: non_neg_integer() | nil
  def decision_count(decision_row, status_row) do
    value =
      Value.get(decision_row, :open_command_count) ||
        Value.get(decision_row, :open_count) ||
        Value.get(decision_row, :count) ||
        Value.get(status_row, :open_decision_count)

    if is_integer(value) and value >= 0, do: value
  end

  @spec command_count_source(map() | term(), map() | term()) :: :decisions | :status_report | :unknown
  def command_count_source(decision_row, _status_row) when not is_nil(decision_row), do: :decisions
  def command_count_source(_decision_row, status_row) when not is_nil(status_row), do: :status_report
  def command_count_source(_decision_row, _status_row), do: :unknown

  @spec activity_value(map() | term(), atom()) :: map()
  def activity_value(activity_row, key) do
    value = Value.get(activity_row, key)
    if is_map(value), do: value, else: %{status: :unknown}
  end

  defp source_value({source, value}, keys) do
    Enum.find_value(keys, &sourced_field(value, &1, source))
  end

  defp sourced_field(value, key, source) do
    value = Value.get(value, key)
    if present?(value), do: {value, source}
  end

  defp sourced_derived_value(issue_fact, status_row, value_fun) do
    [{:canonical_issue, issue_fact}, {:status_report, status_row}]
    |> Enum.find_value({nil, :unknown}, &derived_value(&1, value_fun))
  end

  defp derived_value({source, value}, value_fun) do
    case value_fun.(value) do
      nil -> nil
      derived -> {derived, source}
    end
  end

  defp complexity(issue) do
    case Value.get(issue, :complexity) do
      value when is_integer(value) and value > 0 -> value
      _value -> label_value(issue, "complexity:", &parse_positive_integer/1)
    end
  end

  defp build_lane(issue) do
    Value.get(issue, :build_lane) || label_value(issue, "build-lane:", &normalize_nonempty/1)
  end

  defp label_value(issue, prefix, parser) do
    issue
    |> Value.get(:labels, [])
    |> List.wrap()
    |> Enum.find_value(fn
      label when is_binary(label) ->
        case String.split(label, prefix, parts: 2) do
          ["", value] -> parser.(value)
          _parts -> nil
        end

      _label ->
        nil
    end)
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _value -> nil
    end
  end

  defp normalize_nonempty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      lane -> lane
    end
  end

  defp normalize_nonempty(_value), do: nil

  defp blocking_reason(status_row, waiting) do
    Value.get(status_row, :blocking_reason) || if(waiting in @blocking_reasons, do: waiting)
  end

  defp alert_reason(explicit_alert, count) do
    explicit_alert || if(is_integer(count) and count > 0, do: :open_command)
  end

  defp pause_reason(status_row, pause) do
    pause || if(Value.get(status_row, :tracker_paused) == true, do: :tracker_paused)
  end

  defp stuck_reason(status_row, waiting) do
    Value.get(status_row, :stuck_reason) || if(waiting in [:backing_off, :unresponsive], do: waiting)
  end

  defp present?(value), do: not is_nil(value) and value != ""
end
