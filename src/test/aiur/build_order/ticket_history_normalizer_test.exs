defmodule Aiur.BuildOrder.TicketHistory.NormalizerTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.TicketHistory.{Entry, Normalizer}
  alias Aiur.{TicketObservation, TrackerIdentity}

  test "retains only a fixed category from IssueLog and never its summary" do
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"

    event = %{
      kind: "emit",
      id: 7,
      topic: "ticket.42.pr.review_comment",
      ts: "2026-07-15T12:00:00Z",
      summary: "prompt=#{secret} path=/home/private logs/agent.ndjson terminal output"
    }

    assert {:ok, %Entry{} = entry} = Normalizer.from_issue_log(event, identity())
    assert entry.kind == :pull_request
    assert entry.label == "Pull request updated"
    assert entry.details == %{}
    refute inspect(entry) =~ secret
    refute inspect(entry) =~ "/home/private"
    refute inspect(entry) =~ "agent.ndjson"
    refute inspect(entry) =~ "terminal output"
    refute Map.has_key?(Map.from_struct(entry), :summary)
  end

  test "rejects other-ticket and unsupported IssueLog records" do
    base = %{kind: "emit", id: 7, ts: "2026-07-15T12:00:00Z"}

    assert :ignore = Normalizer.from_issue_log(Map.put(base, :topic, "ticket.43.pr.opened"), identity())
    assert :ignore = Normalizer.from_issue_log(Map.put(base, :topic, "ticket.42.unknown.raw"), identity())
    assert :ignore = Normalizer.from_issue_log(Map.put(base, :kind, "consumed") |> Map.put(:topic, "ticket.42.pr.opened"), identity())
  end

  test "normalizes typed Exchange observations with bounded provenance and attributes" do
    observation = %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity(),
      source: %{kind: :agent_event, name: "progress.checkin"},
      event_id: 8,
      provenance: %{
        run_id: "run-1",
        attempt: 3,
        session_id: "session-2",
        source_event_id: 9,
        local_path: "/home/private",
        credential: "sk-abcdefghijklmnopqrstuvwxyz123456"
      },
      occurred_at: ~U[2026-07-15 11:59:59Z],
      observed_at: ~U[2026-07-15 12:00:00Z],
      attributes: %{percent: 70, prompt: "private", output: "private"}
    }

    assert {:ok, identity, entry} = Normalizer.from_exchange(%{ticket_observation: observation})
    assert identity == identity()
    assert entry.kind == :progress
    assert entry.details == %{percent: 70}
    assert entry.provenance == %{run_id: "run-1", attempt: 3, session_id: "session-2", source_event_id: 9}
    refute inspect(entry) =~ "/home/private"
    refute inspect(entry) =~ "private"
  end

  test "deduplicates by event id, prefers typed Exchange evidence, and retains newest deterministically" do
    disk = entry(1, :issue_log, ~U[2026-07-15 12:00:00Z], %{})
    typed = entry(1, :exchange, ~U[2026-07-15 12:00:00Z], %{percent: 40})
    late = entry(2, :exchange, ~U[2026-07-15 11:59:00Z], %{percent: 20})
    newest = entry(3, :exchange, ~U[2026-07-15 12:01:00Z], %{percent: 60})

    assert {[first, second], true} = Normalizer.merge_entries([disk, late], [typed, newest], 2)
    assert first.event_id == 3
    assert second.event_id == 1
    assert second.source == :exchange
    assert second.details == %{percent: 40}
  end

  defp entry(id, source, observed_at, details) do
    %Entry{
      event_id: id,
      kind: :progress,
      label: "Progress updated",
      source: source,
      observed_at: observed_at,
      occurred_at: observed_at,
      details: details
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
