defmodule Aiur.DecisionRevisionStoreFollowUpTest do
  use ExUnit.Case, async: false

  alias Aiur.{Decision, DecisionEvent, DecisionPubSub, DecisionStore}

  @ticket %{identifier: "985", title: "OCC-8", url: "https://github.com/its-everdred/aiur/issues/985"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: "request-1"}

  @actor %{kind: :operator, id: "operator-1"}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-revision")
    Application.put_env(:aiur, :decision_state_dir, dir)
    :ok = DecisionPubSub.subscribe()

    on_exit(fn ->
      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir}
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

  test "restart repairs a superseded follow-up after its dispatch fence becomes stale", %{dir: dir} do
    parent = self()

    dispatcher = fn dispatched, opts ->
      active = Decision.active_answer(dispatched)
      send(parent, {:revision_dispatched, active.action_id, opts[:attempt_id]})

      if dispatched.revision_sequence == 1 do
        {:no_longer_applicable, :missing}
      else
        {:ok,
         %{
           status: :accepted,
           item: %{id: System.unique_integer([:positive]), status: :pending, correlation: %{attempt_id: opts[:attempt_id]}}
         }}
      end
    end

    scheduler = fn recipient, message, delay_ms ->
      send(parent, {:dispatch_scheduled, recipient, message, delay_ms})
      make_ref()
    end

    resolver = fn resolved, action_id ->
      send(parent, {:follow_up_resolved, action_id, resolved.active_action_id})
      :ok
    end

    opts = [
      dispatcher: dispatcher,
      dispatch_delay_ms: 0,
      reconcile_delay_ms: 0,
      dispatch_scheduler: scheduler,
      revision_follow_up_resolver: resolver
    ]

    pid = start_store!(dir, opts)
    assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000

    {decision, original} = answered_decision(pid)
    assert_receive {:dispatch_scheduled, ^pid, original_dispatch, 0}, 2_000
    send(pid, original_dispatch)
    assert_receive {:revision_dispatched, original_action_id, _attempt_id}, 2_000
    assert original_action_id == original.action_id
    _original_queued = wait_for(pid, decision.decision_id, &(&1.delivery_status == :queued))

    assert {:ok, %{action: first}} = revise(pid, decision, original, "revision-first", "Hold")
    assert_receive {:dispatch_scheduled, ^pid, first_dispatch, 0}, 2_000
    send(pid, first_dispatch)
    assert_receive {:revision_dispatched, first_action_id, _attempt_id}, 2_000
    assert first_action_id == first.action_id

    current = wait_for(pid, decision.decision_id, &Map.has_key?(&1.revision_follow_ups, first.action_id))

    second_payload = %{
      "idempotency_key" => "revision-second",
      "expected_version" => current.version,
      "expected_action_id" => current.active_action_id,
      "expected_revision_sequence" => current.revision_sequence,
      "custom_response" => "Open replacement work",
      "rationale" => "The original target is closed"
    }

    assert {:ok, %{status: :accepted, action: second}} =
             DecisionStore.revise(current.decision_id, second_payload, [actor: @actor], pid)

    assert_receive {:dispatch_scheduled, ^pid, _second_dispatch, 0}, 2_000
    assert_receive {:follow_up_resolved, first_action_id, second_action_id}, 2_000
    assert first_action_id == first.action_id
    assert second_action_id == second.action_id
    GenServer.stop(pid)

    remove_follow_up_handled_event!(dir)
    restarted = start_store!(dir, opts)

    assert_receive {:dispatch_scheduled, ^restarted, {:reconcile_dispatches, [_fence]} = boot_reconciliation, 0}, 2_000

    assert {:ok, %{status: :duplicate, action: ^second}} =
             DecisionStore.revise(current.decision_id, second_payload, [actor: @actor], restarted)

    assert_receive {:dispatch_scheduled, ^restarted, replay_dispatch, 0}, 2_000
    send(restarted, replay_dispatch)
    assert_receive {:revision_dispatched, second_action_id, _attempt_id}, 2_000
    assert second_action_id == second.action_id
    _second_queued = wait_for(restarted, decision.decision_id, &(&1.delivery_status == :queued))

    send(restarted, boot_reconciliation)
    assert_receive {:follow_up_resolved, first_action_id, second_action_id}, 2_000
    assert first_action_id == first.action_id
    assert second_action_id == second.action_id

    repaired = wait_for(restarted, decision.decision_id, & &1.revision_follow_ups[first.action_id].handled_at)
    assert repaired.revision_follow_ups[first.action_id].handled_detail == "Superseded by revision #{second.action_id}"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, restarted)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :follow_up_handled}, &1)) == 1
    refute_receive {:dispatch_scheduled, ^restarted, _message, _delay_ms}, 100
  end

  defp start_store!(dir, opts) do
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

  defp remove_follow_up_handled_event!(dir) do
    path = Path.join(dir, "decisions.ndjson")
    lines = path |> File.read!() |> String.split("\n", trim: true)

    {removed, kept} =
      Enum.reduce(lines, {false, []}, fn line, {removed, kept} ->
        handled? = Jason.decode!(line)["event_type"] == "follow_up_handled"

        if handled? and not removed,
          do: {true, kept},
          else: {removed, [line | kept]}
      end)

    assert removed
    File.write!(path, Enum.join(Enum.reverse(kept), "\n") <> "\n")
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
