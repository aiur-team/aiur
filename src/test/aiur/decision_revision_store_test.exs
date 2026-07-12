defmodule Aiur.DecisionRevisionStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.{Decision, DecisionEvent, DecisionStore}

  @ticket %{identifier: "985", title: "OCC-8", url: "https://github.com/its-everdred/aiur/issues/985"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "request-1"}
  @actor %{kind: :operator, id: "operator-1"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-revision-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "accepts one ordered revision without mutating the original answer", %{dir: dir} do
    pid = start_store!(dir)
    {decision, original} = answered_decision(pid)

    assert {:ok, %{status: :accepted, action: revision, revision_result: :recorded, decision: revised}} =
             revise(pid, decision, original, "revision-1", "Hold the rollout")

    assert revised.answer == original
    assert Decision.active_answer(revised) == revision.answer
    assert revised.active_action_id == revision.action_id
    assert revised.revision_sequence == 1
    assert revised.revisions == [revision]
    assert revision.prior_action_id == original.action_id
    assert revision.reason == "New production evidence"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.map(audit, & &1.type) == [:requested, :answer_recorded, :revision_recorded]
    assert %DecisionEvent{data: ^revision} = List.last(audit)
  end

  test "exact retries survive restart while conflicting token reuse appends nothing", %{dir: dir} do
    pid = start_store!(dir)
    {decision, original} = answered_decision(pid)

    assert {:ok, %{status: :accepted, action: accepted}} =
             revise(pid, decision, original, "revision-replay", "Hold the rollout")

    GenServer.stop(pid)
    restarted = start_store!(dir)

    assert {:ok, %{status: :duplicate, action: replayed}} =
             revise(restarted, decision, original, "revision-replay", "Hold the rollout")

    assert replayed.action_id == accepted.action_id
    assert replayed.content_hash == accepted.content_hash

    assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
             revise(restarted, decision, original, "revision-replay", "Ship anyway")

    assert action_id == accepted.action_id
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, restarted)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "stale correlation and concurrent corrections append at most one revision", %{dir: dir} do
    pid = start_store!(dir)
    {decision, original} = answered_decision(pid)

    stale_payload =
      revision_payload(decision, original, "stale", "Hold")
      |> Map.put("expected_action_id", "act_stale")

    assert {:error, {:conflict, {:stale_action, %{expected: "act_stale", current: current, revision_sequence: 0}}}} =
             DecisionStore.revise(decision.decision_id, stale_payload, [actor: @actor], pid)

    assert current == original.action_id

    calls = [
      Task.async(fn -> revise(pid, decision, original, "race-a", "Direction A") end),
      Task.async(fn -> revise(pid, decision, original, "race-b", "Direction B") end)
    ]

    results = Enum.map(calls, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %{status: :accepted}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:conflict, {:stale_action, _}}}, &1)) == 1

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "dispatch begins only after the revision intent is readable from the audit", %{dir: dir} do
    parent = self()

    dispatcher = fn dispatched, opts ->
      active = Decision.active_answer(dispatched)

      if dispatched.revision_sequence > 0 do
        assert {:ok, audit} = DecisionStore.audit_history(dispatched.decision_id, opts[:store])
        assert Enum.any?(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1))
        send(parent, {:revision_dispatched, active.action_id, opts[:attempt_id]})
      end

      {:ok,
       %{
         status: :accepted,
         item: %{
           id: System.unique_integer([:positive]),
           status: :pending,
           correlation: %{attempt_id: opts[:attempt_id]}
         }
       }}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
    {decision, original} = answered_decision(pid)
    _original_queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))

    assert {:ok, %{action: revision}} =
             revise(pid, decision, original, "revision-dispatch", "Hold the rollout")

    assert_receive {:revision_dispatched, action_id, attempt_id}, 1_000
    assert action_id == revision.action_id
    assert String.starts_with?(attempt_id, revision.action_id <> ":")

    revised = wait_for(pid, decision.decision_id, &(&1.revision_result == :dispatched))
    assert revised.answer == original
    assert revised.delivery_status == :queued
    assert List.last(revised.dispatch_attempts).action_id == revision.action_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.map(audit, & &1.type) == [:requested, :answer_recorded, :dispatch_queued, :revision_recorded, :revision_dispatched]
  end

  test "a fresh missing target records non-applicability without a queue attempt", %{dir: dir} do
    parent = self()

    dispatcher = fn dispatched, opts ->
      if dispatched.revision_sequence > 0 do
        {:no_longer_applicable, :missing}
      else
        {:ok, %{status: :accepted, item: %{id: 17, status: :pending, correlation: %{attempt_id: opts[:attempt_id]}}}}
      end
    end

    projector = fn projected, action_id ->
      follow_up = Map.fetch!(projected.revision_follow_ups, action_id)
      send(parent, {:follow_up_projected, action_id, follow_up.slug, follow_up.question})
      :ok
    end

    resolver = fn resolved, action_id ->
      follow_up = Map.fetch!(resolved.revision_follow_ups, action_id)
      send(parent, {:follow_up_resolved, action_id, follow_up.handled_at})
      :ok
    end

    pid =
      start_store!(dir,
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        revision_follow_up_projector: projector,
        revision_follow_up_resolver: resolver
      )

    {decision, original} = answered_decision(pid)
    _original_queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))

    assert {:ok, %{action: revision}} =
             revise(pid, decision, original, "revision-missing", "Hold the rollout")

    revised =
      wait_for(pid, decision.decision_id, fn current ->
        current.revision_result == :no_longer_applicable and
          Map.has_key?(current.revision_follow_ups, revision.action_id)
      end)

    assert revised.delivery_status == :not_dispatched
    assert revised.revision_outcomes[revision.action_id].reason_class == "target_missing"
    refute Enum.any?(revised.dispatch_attempts, &(&1.action_id == revision.action_id))

    follow_up = Map.fetch!(revised.revision_follow_ups, revision.action_id)
    assert follow_up.slug == Aiur.DecisionRevision.follow_up_slug(revision)
    assert follow_up.question =~ "could not deliver the new direction automatically"
    refute follow_up.question =~ ~r/rolled back|reverted|undone/i
    assert_receive {:follow_up_projected, action_id, slug, _question}, 1_000
    assert action_id == revision.action_id
    assert slug == follow_up.slug

    assert {:ok, %{status: :accepted, handled_at: %DateTime{}}} =
             DecisionStore.handle_revision_follow_up(
               decision.decision_id,
               revision.action_id,
               [actor: @actor, detail: "Escalated to a new ticket"],
               pid
             )

    assert_receive {:follow_up_resolved, action_id, %DateTime{}}, 1_000
    assert action_id == revision.action_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

    assert Enum.map(audit, & &1.type) == [
             :requested,
             :answer_recorded,
             :dispatch_queued,
             :revision_recorded,
             :revision_no_longer_applicable,
             :follow_up_required,
             :follow_up_handled
           ]
  end

  test "restart reprojects one stable unresolved follow-up from the parent audit", %{dir: dir} do
    parent = self()

    dispatcher = fn dispatched, opts ->
      if dispatched.revision_sequence > 0 do
        {:no_longer_applicable, {:terminal, "done"}}
      else
        {:ok, %{status: :accepted, item: %{id: 19, status: :pending, correlation: %{attempt_id: opts[:attempt_id]}}}}
      end
    end

    pid =
      start_store!(dir,
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        revision_follow_up_projector: fn _decision, _action_id -> {:error, :attention_unavailable} end
      )

    {decision, original} = answered_decision(pid)
    _original_queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, %{action: revision}} = revise(pid, decision, original, "revision-restart", "Hold")

    current =
      wait_for(pid, decision.decision_id, fn item ->
        Map.has_key?(item.revision_follow_ups, revision.action_id)
      end)

    slug = current.revision_follow_ups[revision.action_id].slug
    GenServer.stop(pid)

    restarted =
      start_store!(dir,
        reconcile_delay_ms: 0,
        revision_follow_up_projector: fn projected, action_id ->
          send(parent, {:reprojected, action_id, projected.revision_follow_ups[action_id].slug})
          :ok
        end
      )

    assert_receive {:reprojected, action_id, ^slug}, 1_000
    assert action_id == revision.action_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, restarted)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :follow_up_required}, &1)) == 1
  end

  test "a newer revision durably supersedes the prior blocking follow-up before resolution", %{dir: dir} do
    parent = self()

    dispatcher = fn dispatched, opts ->
      if dispatched.revision_sequence > 0 do
        {:no_longer_applicable, :missing}
      else
        {:ok, %{status: :accepted, item: %{id: 23, status: :pending, correlation: %{attempt_id: opts[:attempt_id]}}}}
      end
    end

    pid =
      start_store!(dir,
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        revision_follow_up_resolver: fn resolved, action_id ->
          send(parent, {:superseded_follow_up_resolved, action_id, resolved.active_action_id})
          :ok
        end
      )

    {decision, original} = answered_decision(pid)
    _original_queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, %{action: first}} = revise(pid, decision, original, "revision-first", "Hold")

    current =
      wait_for(pid, decision.decision_id, &Map.has_key?(&1.revision_follow_ups, first.action_id))

    second_payload = %{
      "idempotency_key" => "revision-second",
      "expected_version" => current.version,
      "expected_action_id" => current.active_action_id,
      "expected_revision_sequence" => current.revision_sequence,
      "custom_response" => "Open replacement work",
      "rationale" => "The original target is closed"
    }

    assert {:ok, %{status: :accepted, action: second, decision: revised}} =
             DecisionStore.revise(current.decision_id, second_payload, [actor: @actor], pid)

    first_follow_up = revised.revision_follow_ups[first.action_id]
    assert first_follow_up.handled_by == system_follow_up_actor()
    assert first_follow_up.handled_detail == "Superseded by revision #{second.action_id}"
    assert DateTime.compare(first_follow_up.handled_at, second.recorded_at) in [:eq, :gt]

    assert_receive {:superseded_follow_up_resolved, first_action_id, active_action_id}, 1_000
    assert first_action_id == first.action_id
    assert active_action_id == second.action_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    second_index = Enum.find_index(audit, &match?(%DecisionEvent{type: :revision_recorded, data: ^second}, &1))
    handled_index = Enum.find_index(audit, &match?(%DecisionEvent{type: :follow_up_handled}, &1))
    assert second_index < handled_index
  end

  defp start_store!(dir, opts \\ []) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    defaults = [
      name: nil,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      dispatcher: fn _decision, _opts -> {:error, :not_expected} end,
      revision_follow_up_projector: fn _decision, _action_id -> :ok end,
      revision_follow_up_resolver: fn _decision, _action_id -> :ok end
    ]

    {:ok, pid} =
      DecisionStore.start_link(Keyword.merge(defaults, opts))

    pid
  end

  defp answered_decision(pid) do
    request = %{
      "question" => "Deploy now?",
      "blocking" => true,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(request, [ticket: @ticket, source: @source], pid)

    answer = %{
      "idempotency_key" => "original-answer",
      "expected_version" => decision.version,
      "option_id" => "ship",
      "rationale" => "Initial evidence"
    }

    assert {:ok, %{action: original}} =
             DecisionStore.answer(decision.decision_id, answer, [actor: @actor], pid)

    {decision, original}
  end

  defp revise(pid, decision, prior, token, response) do
    DecisionStore.revise(
      decision.decision_id,
      revision_payload(decision, prior, token, response),
      [actor: @actor],
      pid
    )
  end

  defp revision_payload(decision, prior, token, response) do
    %{
      "idempotency_key" => token,
      "expected_version" => decision.version,
      "expected_action_id" => prior.action_id,
      "expected_revision_sequence" => 0,
      "custom_response" => response,
      "rationale" => "New production evidence"
    }
  end

  defp system_follow_up_actor, do: %{kind: :system, id: "decision-store"}

  defp wait_for(pid, decision_id, predicate, attempts \\ 100)

  defp wait_for(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      Process.sleep(10)
      wait_for(pid, decision_id, predicate, attempts - 1)
    end
  end
end
