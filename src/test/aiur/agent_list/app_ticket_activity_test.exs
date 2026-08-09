defmodule Aiur.AgentList.AppTicketActivityTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentEvents, TrackerIdentity}
  alias Aiur.AgentList.App

  test "subscribes before loading and does not let a queued equal generation overwrite the snapshot" do
    parent = self()
    ticket = identity()
    snapshot = activity(ticket, 70)

    subscribe = fn ->
      send(self(), {
        :ticket_activity_changed,
        %{generation: 2, identity: ticket, snapshot: activity(ticket, 20)}
      })

      send(parent, :subscribed)
      :ok
    end

    snapshot_fun = fn ->
      send(parent, :snapshotted)
      %{generation: 2, entries: [snapshot]}
    end

    {:ok, pid} =
      App.start_link(
        name: nil,
        write_fun: fn _iodata -> :ok end,
        debug?: false,
        ticket_activity_subscribe_fun: subscribe,
        ticket_activity_snapshot_fun: snapshot_fun
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    assert_receive :subscribed
    assert_receive :snapshotted
    send(pid, {:running_changed, [summary(ticket)]})

    assert [{70, _timestamp}] = App.snapshot(pid).progress_by_id["42"]
    refute_receive :snapshotted, 50
  end

  test "AgentList restart reloads the daemon snapshot instead of resetting activity" do
    ticket = identity()
    snapshot_fun = fn -> %{generation: 8, entries: [activity(ticket, 90)]} end

    first = start_app(snapshot_fun)
    send(first, {:running_changed, [summary(ticket)]})
    assert [{90, _timestamp}] = App.snapshot(first).progress_by_id["42"]
    GenServer.stop(first)

    second = start_app(snapshot_fun)
    send(second, {:running_changed, [summary(ticket)]})
    assert [{90, _timestamp}] = App.snapshot(second).progress_by_id["42"]
    GenServer.stop(second)
  end

  test "periodic public reload observes freshness and projection restarts" do
    ticket = identity()
    {:ok, source} = Agent.start_link(fn -> :running end)

    snapshot_fun = fn ->
      case Agent.get(source, & &1) do
        :restarted -> %{generation: 0, entries: []}
        :running -> %{generation: 8, entries: [activity(ticket, 90)]}
      end
    end

    pid = start_app(snapshot_fun)
    send(pid, {:running_changed, [summary(ticket)]})
    assert [{90, _timestamp}] = App.snapshot(pid).progress_by_id["42"]

    Agent.update(source, fn _ -> :restarted end)
    send(pid, :activity_refresh_tick)
    assert App.snapshot(pid).ticket_activity_generation == 0
    assert App.snapshot(pid).progress_by_id == %{}
    GenServer.stop(pid)
  end

  defp start_app(snapshot_fun) do
    {:ok, pid} =
      App.start_link(
        name: nil,
        write_fun: fn _iodata -> :ok end,
        debug?: false,
        ticket_activity_subscribe_fun: fn -> :ok end,
        ticket_activity_snapshot_fun: snapshot_fun
      )

    pid
  end

  defp summary(ticket) do
    AgentEvents.agent_summary("42", :running, 0, %{
      work_state: :working,
      tracker_identity: ticket
    })
  end

  defp activity(ticket, percent) do
    now = DateTime.utc_now()

    %{
      identity: ticket,
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
