defmodule Aiur.TicketObservationTest do
  use ExUnit.Case, async: true

  alias Aiur.{TicketObservation, TrackerIdentity}

  defp identity(owner \\ "owner", repository \\ "repo") do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOExample", "number" => 42},
        {owner, repository},
        {owner, repository}
      )

    identity
  end

  test "keeps configured repository identity separate from source provenance" do
    observed_at = ~U[2026-07-13 12:00:01Z]

    observation =
      TicketObservation.normalize(%{"percent" => 40, "message" => "private model output"},
        identity: identity(),
        source: %{kind: :agent_event, name: "progress"},
        event_id: 73,
        occurred_at: "2026-07-13T12:00:00Z",
        observed_at: observed_at,
        provenance: %{run_id: "run-1", session_id: "session-2", source_event_id: "tool-3"}
      )

    assert observation.version == 1
    assert observation.status == :joinable
    assert observation.tracker_identity == identity()
    assert observation.source == %{kind: :agent_event, name: "progress"}
    assert observation.attributes == %{percent: 40}
    assert observation.occurred_at == ~U[2026-07-13 12:00:00Z]
    assert observation.observed_at == observed_at
    refute Jason.encode!(observation) =~ "private model output"
  end

  test "does not qualify legacy observations from a topic, number, path, or active workflow" do
    observation =
      TicketObservation.normalize(
        %{
          "topic" => "ticket.42.agent.progress",
          "issue" => "42",
          "workspace_path" => "/private/workspaces/owner/repo/42",
          "active_workflow" => "owner/repo",
          "percent" => 90
        },
        source: %{kind: :legacy, name: "ticket.42.agent.progress"}
      )

    assert observation.status == :unattributed
    assert observation.reason == :missing_trusted_identity
    assert observation.tracker_identity == nil
    assert observation.source == %{kind: :legacy, name: "unclassified"}
    assert observation.attributes == %{}
  end

  test "keeps same-number observations in different configured repositories distinct" do
    first = TicketObservation.normalize(%{}, identity: identity("owner", "repo-one"))
    second = TicketObservation.normalize(%{}, identity: identity("owner", "repo-two"))

    assert first.status == :joinable
    assert second.status == :joinable
    assert first.tracker_identity.identifier == second.tracker_identity.identifier
    refute first.tracker_identity == second.tracker_identity
  end

  test "preserves explicit time semantics for malformed, duplicate, and delayed observations" do
    malformed =
      TicketObservation.normalize(%{},
        occurred_at: "not-a-timestamp",
        observed_at: "also-not-a-timestamp"
      )

    first = TicketObservation.normalize(%{}, event_id: 73, occurred_at: "2026-07-13T12:00:00Z", observed_at: "2026-07-13T12:00:01Z")

    duplicate =
      TicketObservation.normalize(%{},
        event_id: 73,
        occurred_at: "2026-07-13T12:00:00Z",
        observed_at: "2026-07-13T12:00:02Z"
      )

    delayed =
      TicketObservation.normalize(%{},
        event_id: 74,
        occurred_at: "2026-07-13T11:59:00Z",
        observed_at: "2026-07-13T12:00:03Z"
      )

    assert malformed.occurred_at == nil
    assert malformed.observed_at == nil
    assert duplicate.event_id == first.event_id
    assert duplicate.occurred_at == first.occurred_at
    assert duplicate.observed_at > first.observed_at
    assert delayed.occurred_at < first.occurred_at
    assert delayed.observed_at > first.observed_at
    assert TicketObservation.normalize(%{}).observed_at == nil
  end

  test "keeps identity stable across retries" do
    first =
      TicketObservation.normalize(%{"percent" => 50},
        identity: identity(),
        source: %{kind: :agent_event, name: "progress.checkin"},
        event_id: 73,
        provenance: %{attempt: 1, session_id: "session-first", source_event_id: "call-1"}
      )

    retry =
      TicketObservation.normalize(%{"percent" => 50},
        identity: identity(),
        source: %{kind: :agent_event, name: "progress.checkin"},
        event_id: 74,
        provenance: %{attempt: 2, session_id: "session-retry", source_event_id: "call-1"}
      )

    assert first.tracker_identity == retry.tracker_identity
    assert first.provenance.attempt == 1
    assert retry.provenance.attempt == 2
    assert first.provenance.session_id != retry.provenance.session_id
  end

  test "redacts unsafe source names and provenance while retaining typed stage attributes" do
    stage =
      TicketObservation.normalize(%{"message" => "secret", "reason" => "private"},
        source: %{kind: :agent_alert, name: "phase.review.start"},
        provenance: %{
          run_id: "run-1",
          session_id: "/private/path",
          source_event_id: "sk-" <> String.duplicate("a", 20)
        }
      )

    unsafe =
      TicketObservation.normalize(%{"message" => "secret", "percent" => 50},
        source: %{kind: :agent_event, name: "prompt: reveal credentials"},
        provenance: %{session_id: "/private/path"}
      )

    assert stage.attributes == %{stage: :review, transition: :start}
    assert stage.provenance == %{run_id: "run-1"}
    assert unsafe.source == %{kind: :agent_event, name: "unclassified"}
    assert unsafe.attributes == %{}
    refute Jason.encode!(stage) =~ "secret"
  end

  test "inventories every migrated agent-event observation" do
    assert %{observations: [:progress, :progress_checkin, :progress_phase]} =
             Enum.find(TicketObservation.producer_inventory(), &(&1.producer == :agent_event))
  end
end
