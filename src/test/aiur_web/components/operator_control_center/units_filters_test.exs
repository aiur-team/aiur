defmodule AiurWeb.OperatorControlCenter.UnitsFiltersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.UnitsFilters

  test "renders one selected scope and independent overlapping condition counts" do
    html =
      render_component(&UnitsFilters.units_filters/1, %{
        selection: %{scope: :unfinished, conditions: [:active, :paused]},
        counts: %{scope: 5, active: 3, alert: 2, paused: 1, stuck: 1, queued: 2, finished: 0}
      })

    assert html =~ ~s(phx-click="select-units-scope")
    assert html =~ ~s(phx-value-scope="unfinished")
    assert html =~ ~r/aria-pressed="true"[^>]+phx-value-scope="unfinished"/
    assert html =~ ~r/aria-pressed="false"[^>]+phx-value-scope="live"/
    assert html =~ ~r/aria-pressed="true"[^>]+phx-value-condition="active"/
    assert html =~ ~r/aria-pressed="true"[^>]+phx-value-condition="paused"/
    assert html =~ ~r/aria-pressed="false"[^>]+phx-value-condition="alert"/
    assert html =~ "Counts describe the selected scope before condition filtering"
    assert html =~ "Conditions overlap, so counts are not additive"
    assert html =~ ~r/>Active<\/span>\s*<span class="units-filter-count num">3<\/span>/
    assert html =~ ~r/>Queued<\/span>\s*<span class="units-filter-count num">2<\/span>/
  end
end
