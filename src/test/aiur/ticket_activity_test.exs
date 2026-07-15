defmodule Aiur.TicketActivityTest do
  use ExUnit.Case, async: false

  alias Aiur.{TicketActivity, TicketObservation, TrackerIdentity}

  setup do
    {:ok, server} =
      TicketActivity.start_link(
        name: nil,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    :ok = TicketActivity.subscribe()
    %{server: server}
  end

  test "publishes a content-free snapshot after applying an exchange observation", %{server: server} do
    ticket = identity()

    send(server, {:event, %{ticket_observation: observation(ticket)}})

    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: snapshot}}, 500
    assert %{progress: %{percent: 40}, latest_evidence: evidence} = snapshot
    refute Map.has_key?(evidence, :message)
    refute inspect(snapshot) =~ "do not retain this raw payload"

    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: server)
  end

  test "refreshes current membership from membership updates", %{server: server} do
    ticket = identity()
    event = %{identity: ticket}

    send(server, {:current_run_membership_changed, %{event: event}})
    send(server, {:event, %{ticket_observation: observation(ticket)}})

    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: %{current: 1, recent: 0}}}}, 500
  end

  test "publishes the retention transition when membership arrives after activity", %{server: server} do
    ticket = identity()
    send(server, {:event, %{ticket_observation: observation(ticket)}})
    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: %{current: 0, recent: 1}}}}, 500

    send(server, {:current_run_membership_changed, %{event: %{identity: ticket}}})
    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: %{current: 1, recent: 0}}}}, 500
  end

  test "consumes qualified observations from the real exchange" do
    ticket = identity()
    event = %{ticket_observation: observation(ticket)}

    {:ok, server} =
      TicketActivity.start_link(
        name: nil,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    Aiur.Events.Exchange.publish("ticket.42.agent.progress", event)

    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: %{progress: %{percent: 40}}}}, 500
    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: server)
  end

  test "restart begins with unknown activity until new trusted evidence arrives" do
    ticket = identity()

    {:ok, first} =
      TicketActivity.start_link(
        name: nil,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        prune_interval_ms: 60_000
      )

    send(first, {:event, %{ticket_observation: observation(ticket)}})
    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: %{progress: %{percent: 40}}}}, 500
    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: first)
    GenServer.stop(first)

    {:ok, restarted} =
      TicketActivity.start_link(
        name: nil,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn ->
      if Process.alive?(restarted), do: GenServer.stop(restarted)
    end)

    assert {:error, :not_found} = TicketActivity.snapshot(ticket, server: restarted)
  end

  defp observation(ticket) do
    %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: ticket,
      source: %{kind: :agent_event, name: "progress"},
      event_id: 1,
      provenance: %{run_id: "run-1", attempt: 1},
      occurred_at: ~U[2026-07-15 12:00:00Z],
      observed_at: ~U[2026-07-15 12:00:01Z],
      attributes: %{percent: 40}
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
