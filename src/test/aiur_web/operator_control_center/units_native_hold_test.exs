defmodule AiurWeb.OperatorControlCenter.UnitsNativeHoldTest do
  use ExUnit.Case, async: true

  import AiurWeb.OperatorControlCenter.UnitsPresenterFixtures

  alias Aiur.Issue
  alias Aiur.Orchestrator.{NativeHold, State, StatusReport}
  alias Aiur.Projections.UnitsPolicy
  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.Presenter.Entries

  test "held question reaches the unit row with Command link, blocked tone and elapsed minutes" do
    now = DateTime.utc_now()
    hold = %{decision_id: "decision-held", since: DateTime.add(now, -420, :second)}
    entry = entry() |> NativeHold.integrate(Map.merge(hold, %{event: :native_question_held, native_ref: "native-1"}))
    [snapshot] = snapshot(entry).running
    assert snapshot.native_hold == hold
    catalog = catalog(snapshot)
    [row] = catalog.snapshot.rows
    assert row.reasons.native_hold == hold
    assert row.tracker_state == "in-progress"
    assert UnitsPolicy.condition?(:waiting_on_you, row)
    assert UnitsPolicy.condition?(:alert, row)
    refute UnitsPolicy.condition?(:active, row)

  end

  test "resolved hold removes waiting state, link and attention" do
    now = DateTime.utc_now()

    entry =
      entry()
      |> NativeHold.integrate(%{event: :native_question_held, native_ref: "native-1", decision_id: "decision-held", since: now})
      |> NativeHold.integrate(%{event: :native_question_resolved, native_ref: "native-1"})

    [snapshot] = snapshot(entry).running
    assert snapshot.native_hold == nil
    catalog = catalog(snapshot)
    [row] = catalog.snapshot.rows
    refute UnitsPolicy.condition?(:waiting_on_you, row)
    assert UnitsPolicy.condition?(:active, row)
  end

  test "future regression guard: unavailable status never invents a held question" do
    catalog = UnitsPresenter.load(%{}, membership_fun: fn -> membership([member(identity("NODE-held", "41"))]) end, activity_fun: fn -> %{entries: []} end)
    [row] = catalog.snapshot.rows
    refute UnitsPolicy.condition?(:waiting_on_you, row)
  end

  defp entry do
    issue = %Issue{id: "NODE-held", identifier: "41", state: "in-progress", tracker_identity: identity("NODE-held", "41")}
    %{identifier: "41", issue: issue, started_at: DateTime.utc_now(), session_id: "session", control: %{status: :working}}
  end

  defp snapshot(entry), do: StatusReport.snapshot_payload(StatusReport.snapshot_input(%State{running: %{entry.issue.id => entry}}))

  defp catalog(snapshot) do
    # Isolate the hold signal from the general open-Command count.
    public = Entries.running_entry_payload(snapshot) |> Map.put(:open_decision_count, 0)
    refute Map.has_key?(public, :native_hold)

    payload = %{
      units_status_snapshot: %{running: [snapshot]},
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      provider_health: %{fleet: :ok},
      fleet: %{running: [public], retrying: [], idle: []}
    }

    UnitsPresenter.load(payload, membership_fun: fn -> membership([]) end, activity_fun: fn -> %{entries: []} end)
  end

end
