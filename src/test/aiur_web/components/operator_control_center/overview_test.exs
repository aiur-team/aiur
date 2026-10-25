defmodule AiurWeb.OperatorControlCenterOverviewTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{History, Overview}

  test "decision banner uses canonical retained counts and hides when none await input" do
    answered = %{decision_id: "dec-answered", blocking: true, lifecycle: :resolved}
    open = %{decision_id: "dec-open", blocking: false, lifecycle: :recorded}

    html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered, open],
        retained_counts: %{open: 1, blocking: 0, awaiting: 1, awaiting_blocking: 0, health: %{status: :available}}
      })

    empty_html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [answered],
        retained_counts: %{open: 0, blocking: 0, awaiting: 0, awaiting_blocking: 0, health: %{status: :available}}
      })

    assert html =~ ~s(href="/commands")
    assert html =~ "1 unit awaiting commands"
    refute empty_html =~ "decisions-banner"
  end

  test "decision banner count equals the open Commands list even when only some block" do
    html =
      render_component(&Overview.decisions_banner/1, %{
        decisions: [],
        retained_counts: %{open: 3, blocking: 1, awaiting: 3, awaiting_blocking: 1, health: %{status: :available}}
      })

    assert html =~ "3 units awaiting commands"
    refute html =~ "1 unit awaiting commands"
  end

  test "the unavailable-counts banner states only what is true on every route" do
    html =
      render_component(&Overview.decisions_banner/1, %{
        retained_counts: %{
          open: nil,
          blocking: nil,
          awaiting: nil,
          awaiting_blocking: nil,
          health: %{status: :unavailable}
        }
      })

    assert html =~ "Command counts unavailable"
    assert html =~ "cannot show how many units are awaiting commands"

    # This banner is on Analytics, Build Order and Stream Deck too, and none of
    # them has a priority overview to fall back to. A degraded surface that
    # names a wrong reason is worse than one that only says the number is gone.
    refute html =~ "priority overview"
  end

  test "distinguishes degraded decision history from an unavailable provider" do
    html = render_component(&History.history/1, %{rows: [], provider_health: :degraded, time_zone: "Etc/UTC"})

    assert html =~ ~s(class="history-count mono" data-count-scope="commands")
    assert html =~ "Showing a partial Command history"
    refute html =~ "currently unavailable"
  end
end
