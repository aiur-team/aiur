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
    assert html =~ ~r/>Active<\/span>\s*<span class="units-filter-count num" aria-label="3">\s*3\s*<\/span>/
    assert html =~ ~r/>Queued<\/span>\s*<span class="units-filter-count num" aria-label="2">\s*2\s*<\/span>/
  end

  test "renders lower-bound counts and names unavailable counts without exact zeros" do
    partial =
      render_component(&UnitsFilters.units_filters/1, %{
        selection: %{scope: :all, conditions: []},
        counts: %{scope: 1_000, active: 800, alert: 2, paused: 1, stuck: 0, queued: 200, finished: 100},
        count_status: :partial
      })

    assert partial =~ "800+"
    assert partial =~ ~s(aria-label="At least 800")

    unavailable =
      render_component(&UnitsFilters.units_filters/1, %{
        selection: %{scope: :live, conditions: []},
        counts: %{scope: nil, active: nil, alert: nil, paused: nil, stuck: nil, queued: nil, finished: nil},
        count_status: :unavailable
      })

    assert unavailable =~ ~s(aria-label="Count unavailable")
    assert unavailable =~ "disabled"
    refute unavailable =~ ~r/units-filter-count num[^>]*>0</
  end
end
