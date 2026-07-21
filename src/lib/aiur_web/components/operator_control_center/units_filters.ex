defmodule AiurWeb.OperatorControlCenter.UnitsFilters do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.UnitsPolicy

  attr(:selection, :map, required: true)
  attr(:counts, :map, required: true)
  attr(:count_status, :atom, default: :exact)

  @spec units_filters(map()) :: Phoenix.LiveView.Rendered.t()
  def units_filters(assigns) do
    assigns =
      assigns
      |> assign(:scopes, [:unfinished])
      |> assign(:conditions, Enum.reject(UnitsPolicy.conditions(), &(&1 == :stuck)))

    ~H"""
    <div class="units-filters">
      <div class="units-filter-list" role="group" aria-label="Unit filters">
        <button
          :for={condition <- @conditions}
          type="button"
          class={[
            "units-filter",
            "condition",
            condition_class(condition),
            UnitsPolicy.selected?(@selection, condition) && "is-selected"
          ]}
          aria-pressed={to_string(UnitsPolicy.selected?(@selection, condition))}
          disabled={@count_status == :unavailable}
          phx-click="toggle-units-condition"
          phx-value-condition={condition}
        >
          <span class="units-filter-dot" aria-hidden="true"></span>
          <span>{label(condition)}</span>
          <span class="units-filter-count num" aria-label={count_aria_label(@counts, condition, @count_status)}>
            {count_label(@counts, condition, @count_status)}
          </span>
        </button>
        <button
          :for={scope <- @scopes}
          type="button"
          class={["units-filter", "scope", @selection.scope == scope && "is-selected"]}
          aria-pressed={to_string(@selection.scope == scope)}
          disabled={@count_status == :unavailable}
          phx-click="select-units-scope"
          phx-value-scope={scope}
        >
          {label(scope)}
        </button>
        <span class="units-filter-divider" aria-hidden="true"></span>
        <button
          type="button"
          class="units-filter scope bulk"
          aria-label="Select all preceding filters"
          disabled={@count_status == :unavailable}
          phx-click="select-all-units-filters"
        >
          All
        </button>
        <button
          type="button"
          class="units-filter scope bulk"
          aria-label="Select no filters"
          disabled={@count_status == :unavailable}
          phx-click="select-no-units-filters"
        >
          None
        </button>
      </div>
    </div>
    """
  end

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp condition_class(:active), do: "is-cond-active"
  defp condition_class(:alert), do: "is-cond-alert"
  defp condition_class(:paused), do: "is-cond-paused"
  defp condition_class(:stuck), do: "is-cond-stuck"
  defp condition_class(:queued), do: "is-cond-queued"
  defp condition_class(:finished), do: "is-cond-finished"
  defp condition_class(_condition), do: "is-cond-generic"

  defp count_label(_counts, _condition, :unavailable), do: "—"
  defp count_label(counts, condition, :partial), do: "#{Map.get(counts, condition, 0)}+"
  defp count_label(counts, condition, _status), do: Map.get(counts, condition, 0)

  defp count_aria_label(_counts, _condition, :unavailable), do: "Count unavailable"

  defp count_aria_label(counts, condition, :partial),
    do: "At least #{Map.get(counts, condition, 0)}"

  defp count_aria_label(counts, condition, _status), do: "#{Map.get(counts, condition, 0)}"
end
