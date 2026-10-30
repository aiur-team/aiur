defmodule Aiur.DecisionCorrectiveOverrideIntegrationTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.{CorrectiveProvenance, CorrectiveTicket}
  alias Aiur.{DecisionPubSub, DecisionStore, Issue}

  test "merged override creates a corrective ticket, records it, and observes its merged PR across restart" do
    dir = Aiur.TestSupport.tmp_root!("corrective-override-integration")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, tracker} = Agent.start_link(fn -> %{ticket: nil, merged: false, creates: 0, comments: %{}} end)
    :ok = DecisionPubSub.subscribe()
    owner = self()
    tracker_opts = tracker_options(tracker)

    opts = store_options(dir, tracker_opts, owner)

    store = start_supervised!({DecisionStore, opts})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{source_id: "colour", question: "Which colour?", blocking: false},
        [ticket: %{identifier: "50", title: "Original", url: nil}, source: %{agent_id: "worker", session_id: "session"}],
        store
      )

    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _answer} = DecisionStore.answer(decision.decision_id, payload("blue"), actor, store)
    context = %{pr: %{number: 60, merged?: true, merge_commit_sha: "original-merge"}, worker: :unknown, capacity: :full}
    {:ok, %{decision: revised}} = DecisionStore.override(decision.decision_id, payload("green"), actor ++ [override_context: context], store)
    action_id = revised.active_action_id
    assert_receive {:corrective_reconciled, ^action_id, {:ok, [{:override_corrective_ticket, _data}]}}, 2_000
    linked = await(store, decision.decision_id, &match?([%{corrective_ticket: %{identifier: "70"}}], &1.overrides))
    assert [%{route: :corrective_ticket, state: :queued}] = linked.overrides
    assert Agent.get(tracker, & &1.creates) == 1
    assert Map.keys(Agent.get(tracker, & &1.comments)) |> Enum.sort() == ["50", "60"]

    stop_supervised!(DecisionStore)
    restarted = start_supervised!({DecisionStore, opts})
    assert {:ok, %{overrides: [%{corrective_ticket: %{identifier: "70"}, state: :queued}]}} = DecisionStore.get(decision.decision_id, restarted)
    Agent.update(tracker, &%{&1 | merged: true})
    send(restarted, :reconcile_corrective_overrides)
    assert_receive {:corrective_reconciled, ^action_id, {:ok, [{:override_corrective_implemented, _data}]}}, 2_000
    implemented = await(restarted, decision.decision_id, &match?([%{state: :implemented}], &1.overrides))
    assert [%{evidence: %{merge_commit_sha: "corrective-merge", pr_number: 80}}] = implemented.overrides
    assert Agent.get(tracker, & &1.creates) == 1
  end

  test "a second override recovers an uncertain prior creation and retains dispatch provenance" do
    dir = Aiur.TestSupport.tmp_root!("corrective-override-uncertain")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, tracker} = Agent.start_link(fn -> %{ticket: nil, merged: false, creates: 0, comments: %{}} end)
    :ok = DecisionPubSub.subscribe()
    tracker_opts = tracker_options(tracker)
    create = tracker_opts[:create]

    uncertain =
      Keyword.put(tracker_opts, :create, fn attrs, opts ->
        {:ok, _ticket} = create.(attrs, opts)
        {:error, :outcome_unknown}
      end)

    store = start_supervised!({DecisionStore, store_options(dir, uncertain, self())})
    request_opts = [ticket: %{identifier: "50", title: "Original", url: nil}, source: %{agent_id: "worker", session_id: "session"}]
    {:ok, %{decision: decision}} = DecisionStore.request(%{source_id: "recovery", question: "Which colour?", blocking: false}, request_opts, store)
    actor = [actor: %{kind: :operator, id: "human"}]
    {:ok, _answer} = DecisionStore.answer(decision.decision_id, payload("blue"), actor, store)
    context = %{pr: %{number: 60, merged?: true, merge_commit_sha: "original-merge"}, worker: :unknown, capacity: :full}
    {:ok, %{decision: first}} = DecisionStore.override(decision.decision_id, payload("green"), actor ++ [override_context: context], store)
    first_action = first.active_action_id
    assert_receive {:corrective_reconciled, ^first_action, {:error, :outcome_unknown}}, 2_000
    stop_supervised!(DecisionStore)
    restarted = start_supervised!({DecisionStore, store_options(dir, tracker_opts, self())})
    {:ok, %{decision: second}} = DecisionStore.override(decision.decision_id, payload("red"), actor ++ [override_context: context], restarted)
    second_action = second.active_action_id
    assert_receive {:corrective_reconciled, ^second_action, {:ok, [_, _]}}, 2_000
    linked = await(restarted, decision.decision_id, &Enum.all?(&1.overrides, fn record -> is_map(record.corrective_ticket) end))
    assert [%{action_id: ^first_action, corrective_ticket: origin_ticket}, %{action_id: ^second_action, corrective_ticket: latest_ticket}] = linked.overrides
    assert origin_ticket == latest_ticket
    original = Agent.get(tracker, & &1.ticket)
    issue = %Issue{id: "70", identifier: "70", url: original["url"], description: original["body"]}
    assert CorrectiveProvenance.check(issue, restarted)
    assert Agent.get(tracker, & &1.creates) == 1
  end

  defp store_options(dir, tracker_opts, owner) do
    [
      name: nil,
      state_dir: dir,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      answer_comment_publisher: fn _ -> :ok end,
      corrective_override_reconciler: fn decision, record ->
        result = CorrectiveTicket.reconcile(decision, record, tracker_opts)
        send(owner, {:corrective_reconciled, record.action_id, result})
        result
      end
    ]
  end

  defp tracker_options(tracker) do
    [
      issue_closure: fn identifier, _ -> {:ok, %{open?: identifier == "70"}} end,
      pull_request: fn
        "50" -> {:ok, %{merged?: true, number: 60, merge_commit_sha: "original-merge"}}
        "70" -> {:ok, if(Agent.get(tracker, & &1.merged), do: %{merged?: true, number: 80, merge_commit_sha: "corrective-merge"}, else: nil)}
      end,
      find: fn marker, _opts ->
        ticket = Agent.get(tracker, & &1.ticket)
        {:ok, if(ticket && String.contains?(ticket["body"], marker), do: ticket)}
      end,
      create: fn attrs, _opts ->
        ticket = %{"number" => 70, "url" => "https://example.test/70", "body" => attrs.body}
        Agent.update(tracker, &%{&1 | ticket: ticket, creates: &1.creates + 1})
        {:ok, ticket}
      end,
      issues: fn
        ["50"] -> {:ok, [%Issue{labels: ["feature:colour"]}]}
        ["70"] -> {:ok, [%Issue{state: "todo"}]}
      end,
      comments: fn target -> {:ok, Agent.get(tracker, &Map.get(&1.comments, target, []))} end,
      comment: fn target, body -> Agent.update(tracker, &put_in(&1, [:comments, target], [%{body: body}])) end
    ]
  end

  defp await(store, id, predicate) do
    {:ok, decision} = DecisionStore.get(id, store)

    if predicate.(decision) do
      decision
    else
      assert_receive {:decision_changed, ^id, _version}, 2_000
      await(store, id, predicate)
    end
  end

  defp payload(token), do: %{expected_version: 1, custom_response: token, rationale: "Changed direction", idempotency_key: token}
end
