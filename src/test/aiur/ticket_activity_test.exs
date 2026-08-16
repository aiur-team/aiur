defmodule Aiur.TicketActivityTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.Exchange
  alias Aiur.{ProgressRetention, TicketActivity, TicketObservation, TrackerIdentity}

  setup do
    {:ok, server} =
      TicketActivity.start_link(
        name: nil,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        # These standalone servers test the projection in isolation, not the
        # retention wiring (covered by the restart-retention test). No-op
        # retention keeps them deterministic even when the suite's supervised
        # default store holds retained readings from other tests.
        retention_retain_fun: fn _identity, _progress -> :ok end,
        retention_all_fun: fn -> %{} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(server)
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

    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: :current}, retention: %{current: 1, recent: 0}}},
                   500
  end

  test "publishes the retention transition when membership arrives after activity", %{server: server} do
    ticket = identity()
    send(server, {:event, %{ticket_observation: observation(ticket)}})

    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: :recent}, retention: %{current: 0, recent: 1}}},
                   500

    send(server, {:current_run_membership_changed, %{event: %{identity: ticket}}})

    assert_receive {:ticket_activity_changed, %{snapshot: %{retention: :current}, retention: %{current: 1, recent: 0}}},
                   500
  end

  test "consumes qualified observations from the real exchange" do
    ticket = identity()
    event = %{ticket_observation: observation(ticket)}

    {:ok, server} =
      TicketActivity.start_link(
        name: nil,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        retention_retain_fun: fn _identity, _progress -> :ok end,
        retention_all_fun: fn -> %{} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(server)
    end)

    Exchange.publish("ticket.42.agent.progress", event)

    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: %{progress: %{percent: 40}}}}, 500
    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: server)
  end

  test "restart without any durable retention begins with unknown activity" do
    ticket = identity()

    # No-op retention isolates this test from the supervised default store:
    # with nothing durably retained, a restart has nothing to seed and the
    # ticket reads as never-reported (`unknown`) until new evidence arrives.
    ticket_activity_opts = [
      name: nil,
      exchange_subscribe_fun: fn -> :ok end,
      membership_subscribe_fun: fn -> :ok end,
      membership_snapshot_fun: fn -> %{members: []} end,
      retention_retain_fun: fn _identity, _progress -> :ok end,
      retention_all_fun: fn -> %{} end,
      prune_interval_ms: 60_000
    ]

    {:ok, first} = TicketActivity.start_link(ticket_activity_opts)

    send(first, {:event, %{ticket_observation: observation(ticket)}})
    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: %{progress: %{percent: 40}}}}, 500
    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: first)
    GenServer.stop(first)

    {:ok, restarted} = TicketActivity.start_link(ticket_activity_opts)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(restarted)
    end)

    assert {:error, :not_found} = TicketActivity.snapshot(ticket, server: restarted)
  end

  test "restart retains the last progress reading from the durable store (#1963)" do
    ticket = identity()
    state_dir = Path.join(System.tmp_dir!(), "ticket-activity-retention-#{System.unique_integer([:positive])}")

    {:ok, retention} = ProgressRetention.start_link(name: nil, state_dir: state_dir)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(retention)
      File.rm_rf!(state_dir)
    end)

    retain_fun = fn identity, progress -> ProgressRetention.retain(identity, progress, server: retention) end
    all_fun = fn -> ProgressRetention.all(server: retention) end

    ticket_activity_opts = [
      name: nil,
      exchange_subscribe_fun: fn -> :ok end,
      membership_subscribe_fun: fn -> :ok end,
      membership_snapshot_fun: fn -> %{members: []} end,
      retention_retain_fun: retain_fun,
      retention_all_fun: all_fun,
      prune_interval_ms: 60_000
    ]

    {:ok, first} = TicketActivity.start_link(ticket_activity_opts)

    send(first, {:event, %{ticket_observation: observation(ticket)}})
    assert_receive {:ticket_activity_changed, %{identity: ^ticket, snapshot: %{progress: %{percent: 40}}}}, 500
    assert {:ok, %{progress: %{percent: 40}}} = TicketActivity.snapshot(ticket, server: first)
    assert :ok = ProgressRetention.flush(server: retention)
    GenServer.stop(first)

    {:ok, restarted} = TicketActivity.start_link(ticket_activity_opts)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(restarted)
    end)

    assert {:ok, %{progress: %{status: :known, percent: 40}}} =
             TicketActivity.snapshot(ticket, server: restarted)
  end

  # `Aiur.Orchestrator.StatusReport.activity_stage/2` reads exactly this shape
  # and deliberately ignores the freshness, because a stage is a state with
  # explicit transitions rather than a measurement that decays: the agent
  # announces `phase.work.start` once and stays in that phase for as long as it
  # takes. A projection change that renamed `:value`, or that dropped the stage
  # once it went stale, would blank the Stream Deck's activity readout for most
  # of every phase.
  test "keeps a known stage after it goes stale, so a long phase stays readable", %{server: server} do
    ticket = identity()
    send(server, {:event, %{ticket_observation: phase_observation(ticket)}})

    assert_receive {:ticket_activity_changed, %{identity: ^ticket}}, 500
    assert {:ok, %{stage: %{status: :known, value: :work, freshness: :stale}}} = TicketActivity.snapshot(ticket, server: server)
  end

  defp phase_observation(ticket) do
    %{
      observation(ticket)
      | source: %{kind: :agent_alert, name: "phase.work.start"},
        event_id: 2,
        attributes: %{stage: :work, transition: :start}
    }
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
