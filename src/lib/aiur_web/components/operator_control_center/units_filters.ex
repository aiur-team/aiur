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
      |> assign(:scopes, UnitsPolicy.scopes())
      |> assign(:conditions, UnitsPolicy.conditions())

    ~H"""
    <div class="units-filters">
      <fieldset class="units-filter-group">
        <legend>Scope</legend>
        <div class="units-filter-list" role="group" aria-label="Units scope">
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
        </div>
      </fieldset>

      <fieldset class="units-filter-group">
        <legend>Conditions</legend>
        <div class="units-filter-list" role="group" aria-label="Unit conditions">
          <button
            :for={condition <- @conditions}
            type="button"
            class={[
              "units-filter",
              "condition",
              UnitsPolicy.selected?(@selection, condition) && "is-selected"
            ]}
            aria-pressed={to_string(UnitsPolicy.selected?(@selection, condition))}
            disabled={@count_status == :unavailable}
            phx-click="toggle-units-condition"
            phx-value-condition={condition}
          >
            <span>{label(condition)}</span>
            <span class="units-filter-count num" aria-label={count_aria_label(@counts, condition, @count_status)}>
              {count_label(@counts, condition, @count_status)}
            </span>
          </button>
        </div>
        <p id="units-filter-note" class="units-filter-note">
          {count_note(@count_status)} Conditions overlap, so counts are not additive.
        </p>
      </fieldset>
    </div>
    """
  end

  defp label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp count_label(_counts, _condition, :unavailable), do: "—"
  defp count_label(counts, condition, :partial), do: "#{Map.get(counts, condition, 0)}+"
  defp count_label(counts, condition, _status), do: Map.get(counts, condition, 0)

  defp count_aria_label(_counts, _condition, :unavailable), do: "Count unavailable"

  defp count_aria_label(counts, condition, :partial),
    do: "At least #{Map.get(counts, condition, 0)}"

  defp count_aria_label(counts, condition, _status), do: "#{Map.get(counts, condition, 0)}"

  defp count_note(:unavailable), do: "Counts are unavailable while the catalog provider is unavailable."
  defp count_note(:partial), do: "Counts are lower bounds for the bounded catalog prefix."
  defp count_note(_status), do: "Counts describe the selected scope before condition filtering."
end
