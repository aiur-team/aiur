defmodule Aiur.AgentList.AppPhaseTrackingTest do
  @moduledoc """
  AgentList renders the typed TicketActivity stage and leaves stale or unknown
  stage state out of the active-phase marker.
  """

  use ExUnit.Case, async: false

  alias Aiur.{AgentEvents, TrackerIdentity}
  alias Aiur.AgentList.App

  setup do
    parent = self()
    identity = identity()

    {:ok, pid} =
      App.start_link(
        write_fun: fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end,
        name: nil,
        subscribe?: false,
        debug?: false
      )

    summary =
      AgentEvents.agent_summary("42", :running, 0, %{
        work_state: :working,
        tracker_identity: identity
      })

    send(pid, {:running_changed, [summary]})
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    %{pid: pid, identity: identity}
  end

  test "fresh stages drive the phase marker and newer clear removes it", context do
    send_activity(context, 0, :work, :fresh)
    assert phase(context.pid) == :work

    send_activity(context, 1, nil, :fresh)
    assert phase(context.pid) == nil
  end

  test "stale stage remains visible as stale evidence but not as an active phase", context do
    send_activity(context, 0, :review, :stale)

    snapshot = App.snapshot(context.pid)
    assert phase(context.pid) == nil
    assert snapshot.activity_status_by_identifier["42"].stage == :stale
    assert snapshot.latest_event_by_id["42"].stale?
  end

  defp send_activity(%{pid: pid, identity: identity}, generation, stage, freshness) do
    now = DateTime.utc_now()

    snapshot = %{
      identity: identity,
      status: freshness,
      progress: %{status: :unknown},
      stage: %{status: :known, freshness: freshness, value: stage, observed_at: now},
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_alert, name: "phase.review.start"},
        attributes: %{stage: :review, transition: :start},
        observed_at: now
      }
    }

    send(pid, {
      :ticket_activity_changed,
      %{generation: generation, identity: identity, snapshot: snapshot}
    })
  end

  defp phase(pid), do: App.snapshot(pid).phase_by_identifier["42"]

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-42",
      identifier: "42",
      reason: nil
    }
  end
end
