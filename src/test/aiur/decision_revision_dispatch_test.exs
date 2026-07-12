defmodule Aiur.DecisionRevisionDispatchTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionAnswer, DecisionRevision, DecisionRevisionDispatch, DecisionValidation, Issue}

  @decision %{
    ticket: %{
      identifier: "tracker-id-985",
      title: "OCC-8",
      url: "https://github.com/its-everdred/aiur/issues/985"
    }
  }
  @terminal_states MapSet.new(["done", "canceled"])

  describe "revalidate_target/2" do
    test "uses the trusted Decision ticket identity for a fresh lookup" do
      parent = self()

      revalidator = fn %Issue{} = issue, fetcher, terminal_states ->
        send(parent, {:revalidated, issue, fetcher, terminal_states})
        {:ok, %Issue{issue | state: "in-progress"}}
      end

      fetcher = fn _ids -> {:ok, []} end

      assert {:ok, refreshed} =
               revalidate(revalidate_fun: revalidator, issue_fetcher: fetcher)

      assert refreshed.state == "in-progress"

      assert_receive {:revalidated, issue, ^fetcher, @terminal_states}
      assert issue.id == "tracker-id-985"
      assert issue.identifier == "tracker-id-985"
      assert issue.title == "OCC-8"
    end

    test "classifies a freshly missing target as no longer applicable" do
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, :missing} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:no_longer_applicable, :missing}
    end

    test "classifies a terminal target as no longer applicable" do
      target = %Issue{id: "tracker-id-985", identifier: "985", state: "Done"}
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, target} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:no_longer_applicable, {:terminal, "Done"}}
    end

    test "keeps a paused non-terminal target applicable for existing wake gates" do
      target = %Issue{id: "tracker-id-985", identifier: "985", state: "In Progress", paused: true}
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, target} end

      assert revalidate(revalidate_fun: revalidator) == {:ok, target}
    end

    test "keeps tracker failures retryable" do
      revalidator = fn _issue, _fetcher, _terminal_states -> {:error, :tracker_unavailable} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:error, {:target_revalidation_failed, :tracker_unavailable}}
    end

    test "fails closed without a durable target identity" do
      assert DecisionRevisionDispatch.revalidate_target(%{ticket: %{identifier: nil}},
               terminal_states: @terminal_states
             ) == {:error, :target_identity_missing}
    end
  end

  describe "dispatch/2" do
    test "queues one factual corrective message after fresh target revalidation" do
      parent = self()
      decision = revised_decision()

      revalidator = fn %Issue{} = issue, _fetcher, _terminal_states ->
        send(parent, {:step, :revalidated, issue.id})
        {:ok, %Issue{issue | state: "in-progress"}}
      end

      sender = fn server, target, payload ->
        send(parent, {:step, :sent, server, target, payload})
        {:ok, %{status: :accepted, item: %{id: 17}}}
      end

      assert {:ok, %{status: :accepted}} =
               DecisionRevisionDispatch.dispatch(decision,
                 attempt_id: "revision-attempt-1",
                 operator_messages: :orchestrator,
                 send_fun: sender,
                 revalidate_fun: revalidator,
                 issue_fetcher: fn _ids -> {:ok, []} end,
                 terminal_states: @terminal_states
               )

      assert_receive {:step, :revalidated, "tracker-id-985"}
      assert_receive {:step, :sent, :orchestrator, "tracker-id-985", payload}
      revision = List.last(decision.revisions)
      assert payload.action_id == revision.action_id
      assert payload.correlation.prior_action_id == revision.prior_action_id
      assert payload.correlation.revision_sequence == 1
      assert payload.correlation.attempt_id == "revision-attempt-1"
      assert payload.body =~ "Inspect the current workspace and target state"
      assert payload.body =~ "earlier instructions may already have taken effect"
      refute payload.body =~ ~r/rolled back|reverted|undone/i
    end

    test "returns semantic non-applicability without touching the queue" do
      parent = self()
      sender = fn _server, _target, _payload -> send(parent, :sent) end
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, :missing} end

      assert DecisionRevisionDispatch.dispatch(revised_decision(),
               attempt_id: "revision-attempt-1",
               send_fun: sender,
               revalidate_fun: revalidator,
               issue_fetcher: fn _ids -> {:ok, []} end,
               terminal_states: @terminal_states
             ) == {:no_longer_applicable, :missing}

      refute_receive :sent
    end
  end

  defp revalidate(overrides) do
    defaults = [
      issue_fetcher: fn _ids -> {:ok, []} end,
      terminal_states: @terminal_states
    ]

    DecisionRevisionDispatch.revalidate_target(@decision, Keyword.merge(defaults, overrides))
  end

  defp revised_decision do
    {:ok, decision} =
      DecisionValidation.normalize(
        %{"question" => "Deploy now?", "blocking" => true},
        ticket: @decision.ticket,
        source: %{agent_id: "agent-1", session_id: "session-1", event_id: "request-1"}
      )

    actor = %{kind: :operator, id: "operator-1"}
    now = ~U[2026-07-12 12:00:00Z]

    {:ok, original} =
      DecisionAnswer.normalize(
        %{
          "idempotency_key" => "original",
          "expected_version" => decision.version,
          "custom_response" => "Proceed"
        },
        decision_id: decision.decision_id,
        decision_version: decision.version,
        actor: actor,
        now: now
      )

    payload = %{
      "idempotency_key" => "revision",
      "expected_version" => decision.version,
      "expected_action_id" => original.action_id,
      "expected_revision_sequence" => 0,
      "custom_response" => "Hold the rollout",
      "rationale" => "New evidence"
    }

    normalizer = fn answer_payload, _opts ->
      DecisionAnswer.normalize(answer_payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        actor: actor,
        now: now
      )
    end

    {:ok, revision} =
      DecisionRevision.normalize(payload,
        decision_id: decision.decision_id,
        decision_version: decision.version,
        current_action_id: original.action_id,
        current_revision_sequence: 0,
        actor: actor,
        now: now,
        answer_normalizer: normalizer
      )

    %{
      decision
      | answer: original,
        active_action_id: revision.action_id,
        revision_sequence: 1,
        revisions: [revision],
        revision_result: :recorded,
        decision_status: :decided,
        delivery_status: :pending
    }
  end
end
