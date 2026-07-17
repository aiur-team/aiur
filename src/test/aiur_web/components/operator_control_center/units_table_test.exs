defmodule AiurWeb.OperatorControlCenter.UnitsTableTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsTable}

  test "renders normalized facts, determinate progress, and only named actions" do
    row = row()
    token = UnitsPresenter.row_token(row)

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(id="unit-#{token}")
    assert html =~ ~s(id="units-inspect-#{token}")
    assert html =~ ~s(phx-click="inspect-unit")
    assert html =~ "acme/aiur #1110"
    assert html =~ "Responsive Units interface"
    assert html =~ "Lane L2"
    assert html =~ "Requested model"
    assert html =~ "gpt-5.6-terra"
    assert html =~ "Resolved model"
    assert html =~ "gpt-5.6"
    assert html =~ "Open Commands"
    assert html =~ "2 open"
    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-valuenow="40")
    assert html =~ "Checkin"
    assert html =~ "Stale"
    assert html =~ "Branch · feature pushed"
    assert html =~ "Inspect ticket"
    assert html =~ "Chat unavailable"
    assert html =~ "Commands"
    assert html =~ ~s(href="/decisions?ticket=1110")
    assert html =~ ~s(href="https://github.com/acme/aiur/issues/1110")
    assert html =~ "Agent log"
    assert html =~ ~s(phx-value-unit="#{token}")
    refute html =~ ~s(phx-value-issue="1110")
    refute html =~ ~r/<tr[^>]+phx-click=/
  end

  test "labels unknown values without fabricating progress, models, or unsafe links" do
    row =
      row()
      |> Map.merge(%{
        url: "https://example.com/private",
        requested_model: nil,
        resolved_model: nil,
        effort: nil,
        complexity: nil,
        build_lane: nil,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown},
        open_command_count: nil,
        provider_health: %{membership: :available, status: :unavailable, activity: :unknown}
      })
      |> put_in([:runtime, :bucket], :idle)
      |> Map.put(:workspace_path, "/private/workspace")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ "Progress unavailable"
    assert html =~ "Progress source"
    assert html =~ "Latest evidence"
    assert html =~ "Requested model"
    assert html =~ "Resolved model"
    assert html =~ "Unknown"
    assert html =~ "Status Unavailable"
    refute html =~ "aria-valuenow"
    refute html =~ "0%"
    refute html =~ "github.com/acme/aiur/issues/1110"
    refute html =~ "example.com"
    refute html =~ "/private/workspace"
    refute html =~ "Agent log"
  end

  test "distinguishes unavailable, healthy-empty, filtered-empty, and stale catalog states" do
    unavailable = render(%{status: :unavailable, message: "membership failed", rows: [], zero_result?: false})
    empty = render(%{status: :empty, message: "No units observed", rows: [], zero_result?: false})
    filtered = render(%{status: :ready, message: nil, rows: [], zero_result?: true})
    stale = render(%{view([row()]) | status: :stale, message: "last known membership"})

    assert unavailable =~ "Units unavailable"
    assert unavailable =~ "membership failed"
    assert empty =~ "No units observed"
    assert filtered =~ "No units match this valid scope"
    assert filtered =~ ~s(phx-click="reset-units-filters")
    assert filtered =~ ~s(class="btn ghost units-reset")
    assert stale =~ "Units may be stale"
    assert stale =~ "last known membership"
    assert stale =~ "Responsive Units interface"

    partial = render(Map.merge(view([row()]), %{truncated?: true, count_status: :partial}))
    assert partial =~ "Units catalog is partial"
    assert partial =~ "Counts are lower bounds"
  end

  defp render(view) do
    render_component(&UnitsTable.units_table/1, %{view: view, now: ~U[2026-07-17 12:00:00Z]})
  end

  defp view(rows) do
    %{status: :ready, message: nil, rows: rows, zero_result?: false}
  end

  defp row do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-1110",
        database_id: 1110,
        identifier: "1110",
        reason: nil
      },
      title: "Responsive Units interface",
      url: "https://github.com/acme/aiur/issues/1110",
      lifecycle: :active,
      terminal?: false,
      replacement_boundary?: false,
      tracker_state: "in-progress",
      backend: :codex,
      agent_family: :codex,
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6",
      effort: :high,
      complexity: 3,
      build_lane: "L2",
      reasons: %{
        waiting: :waiting_for_human,
        blocking: :waiting_for_human,
        alert: :open_command,
        pause: nil,
        stuck: nil
      },
      runtime: %{
        bucket: :running,
        work_state: :working,
        waiting_reason: :waiting_for_human,
        runtime_seconds: 3_900,
        stale_for_seconds: 15,
        tracker_paused?: false,
        membership_lifecycle: :active
      },
      timestamps: %{
        first_observed_at: ~U[2026-07-17 10:00:00Z],
        last_observed_at: ~U[2026-07-17 11:59:00Z],
        started_at: "2026-07-17T10:55:00Z",
        last_activity_at: "2026-07-17T11:59:00Z"
      },
      open_command_count: 2,
      progress: %{status: :known, percent: 40, source: :checkin, freshness: :stale},
      latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}},
      provider_health: %{
        membership: :available,
        status: :available,
        activity: :available,
        decisions: :available,
        issue: :available
      },
      field_sources: %{},
      sources: %{}
    }
  end
end
