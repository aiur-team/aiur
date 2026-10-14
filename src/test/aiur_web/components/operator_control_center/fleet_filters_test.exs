defmodule AiurWeb.OperatorControlCenterComponentsFleetFiltersTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{FleetFilters, FleetTable, History, Overview}

  import AiurWeb.OperatorControlCenterComponentsFixtures

  test "filters real fleet states cumulatively with the latest responsive overview" do
    fleet = %{
      running: [
        fleet_row("AIUR-1", :active),
        fleet_row("AIUR-2", :waiting_for_human),
        fleet_row("AIUR-3", :paused)
      ],
      retrying: [fleet_row("AIUR-4", :backing_off)],
      idle: [
        fleet_row("AIUR-5", :active, state: "done"),
        fleet_row("AIUR-6", :tracker_unavailable)
      ]
    }

    default_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    assert default_html =~ "AIUR-1"
    assert default_html =~ "AIUR-2"
    assert default_html =~ "AIUR-3"
    assert default_html =~ "AIUR-4"
    assert default_html =~ "AIUR-6"
    refute default_html =~ "AIUR-5"
    assert default_html =~ ~s(phx-value-filter="finished")
    assert default_html =~ ~s(aria-label="Fleet filters")

    filters = FleetFilters.default() |> FleetFilters.toggle(:running) |> FleetFilters.toggle(:finished)

    filtered_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z],
        filters: filters
      })

    refute filtered_html =~ "AIUR-1"
    assert filtered_html =~ "AIUR-2"
    assert filtered_html =~ "AIUR-5"
    assert filtered_html =~ "AIUR-6"
  end

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

  test "surfaces DRAFT so a draft PR is never indistinguishable from a blocked one" do
    fleet = %{
      running: [
        fleet_row("AIUR-42", :active,
          title: "Drafting ticket",
          state: "human-review",
          review: :awaiting,
          ci: %{decision: :passed, pr_number: 77, head_sha: "head-77", draft?: true}
        )
      ],
      retrying: [],
      idle: []
    }

    html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    assert html =~ "PR #77"
    assert html =~ "DRAFT"
    assert html =~ "Review awaiting"

    ready_fleet = put_in(fleet, [:running, Access.at(0), :ci, :draft?], false)

    ready_html =
      render_component(&FleetTable.fleet_table/1, %{
        fleet: ready_fleet,
        decisions: [],
        now: ~U[2026-07-12 13:00:00Z]
      })

    refute ready_html =~ "DRAFT"
  end

  test "distinguishes degraded decision history from an unavailable provider" do
    html = render_component(&History.history/1, %{rows: [], provider_health: :degraded, time_zone: "Etc/UTC"})

    assert html =~ ~s(class="history-count mono" data-count-scope="commands")
    assert html =~ "Showing a partial Command history"
    refute html =~ "currently unavailable"
  end
end
