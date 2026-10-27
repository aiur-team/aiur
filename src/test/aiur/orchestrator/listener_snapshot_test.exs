defmodule Aiur.Orchestrator.ListenerSnapshotTest do
  use Aiur.TestSupport
  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{State, StatusReport}
  alias Aiur.Projections.UnitsRow

  test "mode and unread observations survive the status-to-Units projection" do
    issue = %Issue{
      id: "42",
      identifier: "42",
      state: "in-progress",
      title: "Listener",
      tracker_identity: %TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "repo", provider_id: "42", identifier: "42", reason: nil}
    }

    now = DateTime.utc_now()
    record = %{requested: :async, effective: :sync, effective_reason: :pull_tool_unavailable, version: 4, actor: :human}
    entry = %{identifier: "42", issue: issue, started_at: now, listener_effective: record}
    state = %State{running: %{"42" => entry}}
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(state))
    assert [row] = snapshot.running
    assert row.listener.requested == :async
    assert row.listener.version == 4
    assert row.listener.unread_count == 0
    assert %DateTime{} = row.listener.observed_at
    assert row.listener.routing == :legacy
    projected = UnitsRow.snapshot(%{status: Map.merge(snapshot, %{health: :healthy, freshness: %{status: :fresh}})})
    assert [unit] = projected.rows
    assert unit.listener == Map.put(row.listener, :freshness, :fresh)
    assert unit.listener.effective == :sync
  end
end
