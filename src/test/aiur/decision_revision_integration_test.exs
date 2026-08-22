defmodule Aiur.DecisionRevisionIntegrationTest do
  use ExUnit.Case, async: false

  alias Aiur.{Decision, DecisionEvent, DecisionHistory, DecisionPubSub, DecisionStore}

  @ticket %{identifier: "985", title: "OCC-8", url: "https://github.com/its-everdred/aiur/issues/985"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "request-1"}
  @operator %{kind: :operator, id: "operator-1"}
  @target_agent %{kind: :agent, id: "agent-1"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-revision-integration-#{System.pid()}-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)
    :ok = DecisionPubSub.subscribe()

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "preserves and delivers original plus revised actions across restart", %{dir: dir} do
    parent = self()
    counter = :counters.new(1, [])

    dispatcher = fn decision, opts ->
      :counters.add(counter, 1, 1)
      queue_item_id = :counters.get(counter, 1)
      answer = Decision.active_answer(decision)

      item = %{
        id: queue_item_id,
        target_issue_identifier: decision.ticket.identifier,
        action_id: answer.action_id,
        status: :pending,
        correlation: %{
          decision_id: decision.decision_id,
          decision_version: answer.decision_version,
          action_id: answer.action_id,
          attempt_id: opts[:attempt_id]
        }
      }

      send(parent, {:queue_item, answer.action_id, item})
      {:ok, %{status: :accepted, item: item}}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "question" => "Deploy now?",
                 "blocking" => true,
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               [ticket: @ticket, source: @source],
               pid
             )

    answer_payload = %{
      "idempotency_key" => "original-answer",
      "expected_version" => decision.version,
      "option_id" => "ship",
      "rationale" => "Initial evidence"
    }

    assert {:ok, %{action: original}} =
             DecisionStore.answer(decision.decision_id, answer_payload, [actor: @operator], pid)

    assert_receive {:queue_item, original_action_id, original_item}, 1_000
    assert original_action_id == original.action_id
    _queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.record_delivery(original_item, pid)
    _delivered = wait_for(pid, decision.decision_id, &(&1.delivery_status == :delivered))

    assert {:ok, %{status: :accepted}} = acknowledge(pid, decision, original.action_id)
    assert {:ok, %{status: :accepted}} = resolve(pid, decision, original.action_id)

    revision_payload = %{
      "idempotency_key" => "revision-answer",
      "expected_version" => decision.version,
      "expected_action_id" => original.action_id,
      "expected_revision_sequence" => 0,
      "custom_response" => "Hold the rollout",
      "rationale" => "New production evidence"
    }

    assert {:ok, %{status: :accepted, action: revision}} =
             DecisionStore.revise(decision.decision_id, revision_payload, [actor: @operator], pid)

    assert_receive {:queue_item, revision_action_id, revision_item}, 1_000
    assert revision_action_id == revision.action_id
    _revision_queued = wait_for(pid, decision.decision_id, &(&1.revision_result == :dispatched))
    assert {:ok, :accepted} = DecisionStore.record_delivery(revision_item, pid)
    _revision_delivered = wait_for(pid, decision.decision_id, &(&1.delivery_status == :delivered))

    assert {:ok, %{status: :accepted}} = acknowledge(pid, decision, revision.action_id)
    assert {:ok, %{status: :accepted}} = resolve(pid, decision, revision.action_id)

    assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
    assert current.answer == original
    assert Decision.active_answer(current) == revision.answer
    assert current.active_action_id == revision.action_id
    assert current.revision_sequence == 1
    assert current.acknowledgements[original.action_id].action_id == original.action_id
    assert current.acknowledgements[revision.action_id].action_id == revision.action_id
    assert current.resolutions[original.action_id].action_id == original.action_id
    assert current.resolutions[revision.action_id].action_id == revision.action_id

    attempts = Enum.group_by(current.dispatch_attempts, & &1.action_id)
    assert [%{status: :delivered}] = attempts[original.action_id]
    assert [%{status: :delivered}] = attempts[revision.action_id]

    history = DecisionHistory.list(server: pid, limit: 100)
    answered = Enum.find(history, &(&1.change == :answered and &1.action_id == original.action_id))
    revised = Enum.find(history, &(&1.revision_result == :dispatched and &1.action_id == revision.action_id))

    assert answered.actor.type == :human_operator
    assert answered.choice == "ship"
    assert revised.change == :revised
    assert revised.prior_action_id == original.action_id
    assert revised.revision_sequence == 1
    assert revised.choice == "Hold the rollout"
    assert revised.rationale == "New production evidence"
    assert revised.ticket.identifier == "985"
    refute inspect(revised) =~ ~r/rolled back|reverted|undone/i

    assert {:ok, %{status: :duplicate, action: replayed}} =
             DecisionStore.revise(decision.decision_id, revision_payload, [actor: @operator], pid)

    assert replayed.action_id == revision.action_id
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, replayed_current} = DecisionStore.get(decision.decision_id, restarted)
    assert replayed_current.answer == original
    assert Decision.active_answer(replayed_current) == revision.answer
    assert replayed_current.active_action_id == revision.action_id
    assert replayed_current.decision_status == :resolved
    assert replayed_current.dispatch_attempts == current.dispatch_attempts
  end

  defp start_store!(dir, opts \\ []) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    defaults = [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      dispatcher: fn _decision, _opts -> {:error, :not_expected} end,
      revision_follow_up_projector: fn _decision, _action_id -> :ok end,
      revision_follow_up_resolver: fn _decision, _action_id -> :ok end
    ]

    {:ok, pid} = DecisionStore.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp acknowledge(pid, decision, action_id) do
    DecisionStore.agent_lifecycle(
      :acknowledged,
      %{decision_id: decision.decision_id, action_id: action_id, expected_version: decision.version},
      [ticket_identifier: @ticket.identifier, actor: @target_agent, source: @source],
      pid
    )
  end

  defp resolve(pid, decision, action_id) do
    DecisionStore.agent_lifecycle(
      :resolved,
      %{decision_id: decision.decision_id, action_id: action_id, expected_version: decision.version},
      [ticket_identifier: @ticket.identifier, actor: @target_agent, source: @source],
      pid
    )
  end

  defp wait_for(pid, decision_id, predicate, attempts \\ 100)

  defp wait_for(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^decision_id, _version}, 2_000
      wait_for(pid, decision_id, predicate, attempts - 1)
    end
  end
end
