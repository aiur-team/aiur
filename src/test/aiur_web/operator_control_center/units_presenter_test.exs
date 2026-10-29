defmodule AiurWeb.OperatorControlCenter.UnitsPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{State, StatusReport}
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsURL}

  import AiurWeb.OperatorControlCenter.UnitsPresenterFixtures

  test "unpublished daemon snapshot renders Units as loading without zero counts" do
    catalog = UnitsPresenter.load(%{daemon_starting?: true}, membership_fun: fn -> raise "must not read yet" end)
    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert view.status == :loading
    assert view.message == "The daemon is starting."
    assert view.total_count == nil
    assert view.count_status == :loading
    assert Enum.all?(Map.values(view.counts), &is_nil/1)
    assert UnitsPanel.units_count_label(view) == "loading units…"
    assert UnitsPresenter.announcement(view) =~ "Loading Units"
  end

  test "loads typed provider snapshots once and keeps later projection pure" do
    test_pid = self()
    alpha = identity("NODE-alpha", "41")

    membership_fun = fn ->
      send(test_pid, :membership_read)
      membership([member(alpha)])
    end

    activity_fun = fn ->
      send(test_pid, :activity_read)

      %{
        generation: 8,
        entries: [
          %{
            identity: alpha,
            progress: %{status: :known, percent: 60, source: :checkin, freshness: %{status: :fresh}},
            latest_evidence: %{status: :known, source: :agent_event, occurred_at: ~U[2026-07-17 12:00:00Z]}
          }
        ]
      }
    end

    catalog = UnitsPresenter.load(payload(alpha), membership_fun: membership_fun, activity_fun: activity_fun)

    assert_received :membership_read
    assert_received :activity_read
    assert catalog.status == :ready

    assert [row] = catalog.snapshot.rows
    assert row.identity == alpha
    assert row.title == "Render Units"
    assert row.backend == "codex"
    assert row.agent_family == "codex"
    assert row.requested_model == "gpt-5.6"
    assert row.effort == "high"
    assert row.complexity == 3
    assert row.build_lane == "dashboard-ui"
    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.provider_health.decisions == :degraded
    assert row.progress.percent == 60
    refute Map.has_key?(row, :workspace_path)

    view = UnitsPresenter.project(catalog, %{scope: :all, conditions: [:active, :alert]})

    assert view.selection == %{scope: :all, conditions: [:active, :alert]}
    assert view.rows == [row]
    assert view.counts.active == 1
    assert view.counts.alert == 1
    assert view.counts.scope == 1
    refute_received :membership_read
    refute_received :activity_read
  end

  test "Units rows preserve internal attempt, context, and usage reset measurements" do
    identity = identity("NODE-usage", "41")
    issue = %Issue{id: "NODE-usage", identifier: "41", state: "in-progress", tracker_identity: identity}

    # Build the internal row with the orchestrator snapshot builder, so a key it drops never reaches the presenter.
    entry = %{
      identifier: "41",
      issue: issue,
      paused_reason: :usage_limit_exhausted,
      control: %{status: :paused},
      usage_limit_reset_at: "2026-07-17T13:00:00Z",
      telemetry_attempt_id: "attempt-current",
      turn_count: 3,
      context_usage: %{used_tokens: 1200, window_tokens: 4000, used_percent: 30.0, session_id: "private-session"}
    }

    [internal_row] = StatusReport.snapshot_payload(StatusReport.snapshot_input(%State{running: %{issue.id => entry}})).running

    catalog =
      UnitsPresenter.load(
        %{
          generated_at: "2026-07-17T12:00:00Z",
          provider_health: %{fleet: :ok, decisions: :ok},
          units_status_snapshot: %{
            running: [internal_row],
            retrying: [],
            idle: [],
            snapshot_freshness: %{status: :current, observed_at: "2026-07-17T12:00:00Z", age_seconds: 0}
          },
          fleet: %{running: [fleet_entry(identity)], retrying: [], idle: []},
          decisions: []
        },
        membership_fun: fn -> membership([member(identity)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert [row] = catalog.snapshot.rows
    assert row.telemetry_attempt_id == "attempt-current"
    assert row.runtime.usage_limit_reset_at == "2026-07-17T13:00:00Z"
    assert row.context_usage == %{used_tokens: 1200, window_tokens: 4000, used_percent: 30.0}
    refute Map.has_key?(row.context_usage, :session_id)
    assert row.turn_count == 3
    assert row.field_sources.turn_count == :status_report
  end

  test "current orchestrator rows prevent a healthy empty membership from reporting Active 0" do
    alpha = identity("NODE-restarted", "41")

    catalog =
      UnitsPresenter.load(payload(alpha),
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert catalog.status == :ready
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
    assert view.counts.active == 1
    refute UnitsPresenter.announcement(view) =~ "No units in this run yet"
  end

  test "provider failure is named unavailable instead of becoming a healthy empty catalog" do
    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> raise "membership down" end,
        activity_fun: fn -> exit(:activity_down) end
      )

    assert catalog.status == :unavailable
    assert catalog.message == "Fleet data is unavailable."
    assert catalog.snapshot.rows == []
    assert catalog.snapshot.health.membership == :unavailable
    assert catalog.snapshot.health.activity == :unavailable

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())
    assert view.total_count == nil
    assert view.count_status == :unavailable
    assert Enum.all?(view.counts, fn {_name, count} -> is_nil(count) end)
    assert UnitsPresenter.announcement(view) =~ "No live units"
    refute UnitsPresenter.announcement(view) =~ "0 of 0"
  end

  test "unavailable membership with current agents reports unknown counts instead of zero" do
    alpha = identity("NODE-membership-unavailable", "41")

    catalog =
      UnitsPresenter.load(payload(alpha),
        membership_fun: fn -> raise "membership down" end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert catalog.status == :stale
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
    assert view.count_status == :partial
    assert view.counts.active == 1
    assert catalog.message == "Fleet data is unavailable."
  end

  test "an unpublished daemon view becomes unavailable after the startup deadline" do
    catalog = UnitsPresenter.load(%{daemon_starting?: true, startup_elapsed_ms: 600_000})
    view = UnitsPresenter.project(catalog, UnitsURL.default_selection())

    assert catalog.status == :unavailable
    assert view.count_status == :unavailable
    assert is_nil(view.total_count)
    assert catalog.message == "Fleet data is unavailable."
  end

  test "a fleet catalog with no successful view is marked loading during startup" do
    payload = %{units: %{status: :stale, message: "Fleet data is unavailable.", snapshot: %{rows: []}}}

    assert %{units: %{status: :loading, message: "The daemon is starting."}} = UnitsPresenter.starting_catalog(payload)
  end

  test "truncated membership qualifies every catalog count as a lower bound" do
    identities = Enum.map(1..1_001, &identity("NODE-#{&1}", Integer.to_string(&1)))
    retained = identities |> Enum.take(1_000) |> Enum.map(&member/1)

    bounded_membership =
      retained
      |> membership()
      |> Map.put(:truncated?, length(identities) > length(retained))

    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> bounded_membership end,
        activity_fun: fn -> %{entries: []} end
      )

    view = UnitsPresenter.project(catalog, %{scope: :all, conditions: []})

    assert view.truncated?
    assert view.count_status == :partial
    assert view.total_count == 1_000
    assert view.counts.scope == 1_000
    assert UnitsPresenter.announcement(view) =~ "at least 1000 of at least 1000 Units"
  end

  test "same-count row changes produce a bounded production announcement revision" do
    alpha = identity("NODE-announcement", "41")
    catalog = UnitsPresenter.load(payload(alpha), membership_fun: fn -> membership([member(alpha)]) end)
    before = UnitsPresenter.project(catalog, %{scope: :all, conditions: []})

    updated_catalog = update_in(catalog, [:snapshot, :rows], fn [row] -> [%{row | title: "Updated title"}] end)
    after_update = UnitsPresenter.project(updated_catalog, %{scope: :all, conditions: []})

    assert before.total_count == after_update.total_count
    assert length(before.rows) == length(after_update.rows)
    refute before.revision == after_update.revision
    refute UnitsPresenter.announcement(before) == UnitsPresenter.announcement(after_update)
    assert UnitsPresenter.announcement(after_update) =~ ~r/Update [a-f0-9]{10}/
  end

  test "unknown membership health never renders as a healthy empty catalog" do
    catalog =
      UnitsPresenter.load(%{},
        membership_fun: fn -> %{members: [], health: :unknown, freshness: %{status: :unknown}} end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :unavailable
    assert catalog.message == "Fleet data is unavailable."
    assert catalog.snapshot.health.membership == :unknown
  end
end
