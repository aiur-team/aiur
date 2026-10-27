defmodule AiurWeb.Api.UsageProgressTest do
  # `use Aiur.TestSupport` points `:log_file` at a per-test root, so the IssueLog
  # files written here are this test's alone.
  use Aiur.TestSupport

  alias Aiur.{IssueLog, TicketActivity, TicketObservation, TrackerIdentity}
  alias AiurWeb.Api.UsageProgress

  @now ~U[2026-07-15 12:00:30Z]

  setup do
    {:ok, server} =
      TicketActivity.start_link(
        name: nil,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        membership_snapshot_fun: fn -> %{members: []} end,
        retention_retain_fun: fn _identity, _progress -> :ok end,
        retention_all_fun: fn -> %{} end,
        prune_interval_ms: 60_000
      )

    on_exit(fn -> Aiur.TestSupport.safe_stop(server) end)
    %{server: server, ticket: identity()}
  end

  test "an external caller sees the current phase and the latest progress", %{server: server, ticket: ticket} do
    apply_observations(server, [
      phase(ticket, "work", :start, 1, ~U[2026-07-15 12:00:00Z]),
      progress(ticket, "progress", 30, 2, ~U[2026-07-15 12:00:05Z]),
      progress(ticket, "progress.checkin", 55, 3, ~U[2026-07-15 12:00:20Z])
    ])

    write_bus_log(ticket.identifier, ["2026-07-15T12:00:20Z [event:self] id=3 ticket.#{ticket.identifier}.agent.progress.checkin: 55%"])

    assert {:ok, payload} = UsageProgress.payload(ticket.identifier, seams(server))

    # The documented field set exactly: a leaked internal field fails here.
    assert payload |> Map.keys() |> Enum.sort() ==
             ~w(contract contract_version events generated_at issue_identifier phase progress repository sources)

    assert payload["contract"] == "aiur.ticket_progress"
    assert payload["contract_version"] == 1
    assert payload["repository"] == "owner/repo"
    assert payload["phase"] == %{"status" => "known", "value" => "work", "observed_at" => "2026-07-15T12:00:00Z"}
    # The newest reading wins, and it is reported as a check-in, not a phase estimate.
    assert payload["progress"] == %{
             "status" => "known",
             "percent" => 55,
             "source" => "checkin",
             "freshness" => "fresh",
             "occurred_at" => "2026-07-15T12:00:20Z",
             "observed_at" => "2026-07-15T12:00:20Z"
           }

    assert [%{"id" => 3, "type" => "checkin", "summary" => "55%"}] = payload["events"]
    assert payload["sources"] == %{"activity" => "available"}
  end

  test "progress events come back oldest first and only for this ticket", %{server: server, ticket: ticket} do
    id = ticket.identifier

    write_bus_log(id, [
      "2026-07-15T12:00:00Z [event:emit_alert] id=1 ticket.#{id}.agent.phase.plan.start: plan",
      "2026-07-15T12:00:01Z [event:self] id=2 ticket.#{id}.agent.progress: 10%",
      "2026-07-15T12:00:02Z [event:emit] id=3 ticket.#{id}.pr.opened: PR #9",
      # A dependency's progress delivered to this agent is not this ticket's progress.
      "2026-07-15T12:00:03Z [event:consumed] id=4 ticket.999.agent.progress: 90%",
      # Not a workflow phase, so not phase history.
      "2026-07-15T12:00:03Z [event:emit_alert] id=7 ticket.#{id}.agent.phase.deploy.start: deploy",
      "2026-07-15T12:00:04Z [event:emit_alert] id=5 ticket.#{id}.agent.phase.plan.end: plan",
      "2026-07-15T12:00:05Z [event:self] id=6 ticket.#{id}.agent.progress.checkin: 40% tests green"
    ])

    assert {:ok, payload} = UsageProgress.payload(id, seams(server))

    assert Enum.map(payload["events"], & &1["id"]) == [1, 2, 5, 6]
    assert Enum.map(payload["events"], & &1["type"]) == ["phase", "progress", "phase", "checkin"]
    assert [%{"phase" => "plan", "transition" => "start"}, _, %{"phase" => "plan", "transition" => "end"}, last] = payload["events"]
    assert last == %{"id" => 6, "type" => "checkin", "topic" => "agent.progress.checkin", "label" => "Progress check-in", "summary" => "40% tests green", "at" => "2026-07-15T12:00:05Z"}
  end

  test "the limit keeps the newest events, still in order", %{server: server, ticket: ticket} do
    id = ticket.identifier
    write_bus_log(id, for(n <- 1..5, do: "2026-07-15T12:00:0#{n}Z [event:self] id=#{n} ticket.#{id}.agent.progress: #{n * 10}%"))

    assert {:ok, payload} = UsageProgress.payload(id, [limit: 2] ++ seams(server))
    assert Enum.map(payload["events"], & &1["summary"]) == ["40%", "50%"]
  end

  test "an unknown ticket is reported as unknown, never as idle or 0%", %{server: server, ticket: ticket} do
    assert {:ok, payload} = UsageProgress.payload(ticket.identifier, seams(server))

    assert payload["phase"] == %{"status" => "unknown"}
    assert payload["progress"] == %{"status" => "unknown"}
    assert payload["events"] == []
    assert payload["repository"] == nil
    assert payload["sources"] == %{"activity" => "available"}
  end

  test "a finished phase is known with no value, not unknown", %{server: server, ticket: ticket} do
    apply_observations(server, [
      phase(ticket, "work", :start, 1, ~U[2026-07-15 12:00:00Z]),
      phase(ticket, "work", :end, 2, ~U[2026-07-15 12:00:10Z])
    ])

    assert {:ok, %{"phase" => %{"status" => "known", "value" => nil}}} = UsageProgress.payload(ticket.identifier, seams(server))
  end

  test "an unreadable projection says unavailable and falls back to the retained reading", %{ticket: ticket} do
    retained = %{key: %{identity: ticket, progress: %{percent: 70, source: :phase, observed_at: ~U[2026-07-15 11:00:00Z]}}}

    opts = [
      activity_fun: fn -> exit(:timeout) end,
      retention_fun: fn -> retained end,
      now: @now
    ]

    assert {:ok, payload} = UsageProgress.payload(ticket.identifier, opts)

    # The measured 70% survives as stale; it is never replaced with 0.
    assert %{"status" => "known", "percent" => 70, "freshness" => "stale", "source" => "phase"} = payload["progress"]
    assert payload["phase"] == %{"status" => "unknown"}
    assert payload["repository"] == "owner/repo"
    assert payload["sources"]["activity"] == "unavailable"
  end

  test "a projection answering an unexpected shape is unavailable, not an empty ticket", %{ticket: ticket} do
    opts = [activity_fun: fn -> {:error, :booting} end, retention_fun: fn -> :not_a_map end, now: @now]

    assert {:ok, payload} = UsageProgress.payload(ticket.identifier, opts)
    assert payload["sources"]["activity"] == "unavailable"
    assert payload["progress"] == %{"status" => "unknown"}
  end

  test "a retained reading from another repository's same-numbered ticket is not mixed in", %{server: server, ticket: ticket} do
    apply_observations(server, [phase(ticket, "work", :start, 1, ~U[2026-07-15 12:00:00Z])])
    other_repo = %{ticket | owner: "other", repository: "fork", provider_id: "I-other"}

    retained = %{
      same: %{identity: ticket, progress: %{percent: 20, source: :phase, observed_at: ~U[2026-07-15 10:00:00Z]}},
      # Newer, so a bare-identifier pick would choose it.
      other: %{identity: other_repo, progress: %{percent: 90, source: :checkin, observed_at: ~U[2026-07-15 11:00:00Z]}}
    }

    opts = Keyword.put(seams(server), :retention_fun, fn -> retained end)
    assert {:ok, payload} = UsageProgress.payload(ticket.identifier, opts)

    assert payload["repository"] == "owner/repo"
    assert %{"percent" => 20, "freshness" => "stale"} = payload["progress"]

    only_other = Keyword.put(seams(server), :retention_fun, fn -> Map.delete(retained, :same) end)
    assert {:ok, %{"progress" => %{"status" => "unknown"}}} = UsageProgress.payload(ticket.identifier, only_other)
  end

  test "an out-of-range reading is unknown, never clamped to a percent", %{ticket: ticket} do
    retained = %{key: %{identity: ticket, progress: %{percent: 150, source: :phase, observed_at: ~U[2026-07-15 11:00:00Z]}}}
    opts = [activity_fun: fn -> %{entries: []} end, retention_fun: fn -> retained end, now: @now]

    assert {:ok, %{"progress" => %{"status" => "unknown"}}} = UsageProgress.payload(ticket.identifier, opts)
  end

  test "a fractional reading is rendered as a whole percent", %{ticket: ticket} do
    retained = %{key: %{identity: ticket, progress: %{percent: 70.6, source: :checkin, observed_at: ~U[2026-07-15 11:00:00Z]}}}
    opts = [activity_fun: fn -> %{entries: []} end, retention_fun: fn -> retained end, now: @now]

    assert {:ok, %{"progress" => %{"percent" => 71}}} = UsageProgress.payload(ticket.identifier, opts)
  end

  test "identifiers that are not ticket-shaped are rejected" do
    for identifier <- ["", "../etc", "a/b", String.duplicate("9", 65), nil] do
      assert UsageProgress.payload(identifier) == {:error, :invalid_identifier}
    end
  end

  defp seams(server) do
    [
      activity_fun: fn -> TicketActivity.snapshots(server: server, now: @now) end,
      retention_fun: fn -> %{} end,
      now: @now
    ]
  end

  # The server handles its mailbox in order, so a call after the sends returns
  # only once every observation has been applied.
  defp apply_observations(server, observations) do
    for observation <- observations, do: send(server, {:event, %{ticket_observation: observation}})
    _ = TicketActivity.snapshots(server: server)
    :ok
  end

  defp progress(ticket, name, percent, event_id, observed_at) do
    observation(ticket, %{kind: :agent_event, name: name}, %{percent: percent}, event_id, observed_at)
  end

  defp phase(ticket, stage, transition, event_id, observed_at) do
    source = %{kind: :agent_alert, name: "phase.#{stage}.#{transition}"}
    observation(ticket, source, %{stage: String.to_existing_atom(stage), transition: transition}, event_id, observed_at)
  end

  defp observation(ticket, source, attributes, event_id, observed_at) do
    %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: ticket,
      source: source,
      event_id: event_id,
      provenance: %{run_id: "run-1", attempt: 1},
      occurred_at: observed_at,
      observed_at: observed_at,
      attributes: attributes
    }
  end

  defp identity do
    ticket = Integer.to_string(System.unique_integer([:positive]))

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-#{ticket}",
      identifier: ticket,
      reason: nil
    }
  end

  defp write_bus_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end
end
