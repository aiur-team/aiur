defmodule Aiur.AgentList.AppProgressRatchetTest do
  @moduledoc """
  AgentList consumes already-ratchet-validated TicketActivity progress and
  applies each projection generation at most once.
  """

  use ExUnit.Case, async: false

  alias Aiur.{AgentEvents, TrackerIdentity}
  alias Aiur.AgentList.App

  setup do
    parent = self()
    identity = identity("42")

    {:ok, pid} =
      App.start_link(
        write_fun: fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end,
        name: nil,
        subscribe?: false,
        debug?: false,
        ticket_activity_snapshot_fun: fn -> snapshots(4, [activity(identity, 85)]) end
      )

    send(pid, {:running_changed, [summary("42", identity)]})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid, identity: identity}
  end

  test "applies an exact next generation once", %{pid: pid, identity: identity} do
    send(pid, {:ticket_activity_changed, update(0, identity, activity(identity, 40))})
    assert head_percent(pid, "42") == 40

    send(pid, {:ticket_activity_changed, update(1, identity, activity(identity, 70))})
    assert head_percent(pid, "42") == 70
    assert length(App.snapshot(pid).progress_by_id["42"]) == 2

    send(pid, {:ticket_activity_changed, update(1, identity, activity(identity, 10))})
    assert head_percent(pid, "42") == 70
    assert length(App.snapshot(pid).progress_by_id["42"]) == 2
  end

  test "reloads a missed generation from the public snapshot", %{pid: pid, identity: identity} do
    send(pid, {:ticket_activity_changed, update(3, identity, activity(identity, 10))})

    assert head_percent(pid, "42") == 85
    assert App.snapshot(pid).ticket_activity_generation == 4
  end

  defp head_percent(pid, id) do
    case App.snapshot(pid).progress_by_id[id] do
      [{percent, _timestamp} | _] -> percent
      _ -> nil
    end
  end

  defp summary(id, identity) do
    AgentEvents.agent_summary(id, :running, 0, %{
      work_state: :working,
      tracker_identity: identity
    })
  end

  defp activity(identity, percent) do
    now = DateTime.utc_now()

    %{
      identity: identity,
      status: :fresh,
      progress: %{
        status: :known,
        freshness: :fresh,
        percent: percent,
        observed_at: now,
        provenance: %{run_id: "run-1", attempt: 1}
      },
      stage: %{status: :unknown},
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress"},
        attributes: %{percent: percent},
        observed_at: now
      }
    }
  end

  defp update(generation, identity, snapshot),
    do: %{generation: generation, identity: identity, snapshot: snapshot}

  defp snapshots(generation, entries), do: %{generation: generation, entries: entries}

  defp identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
