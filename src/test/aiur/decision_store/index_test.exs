Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.IndexTest do
  use Aiur.DecisionStoreCase, async: false

  test "dashboard projections stay bounded with 10k stored decisions", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Bound this history?", "blocking" => false})
    %{audit_history: audit_history} = :sys.get_state(pid)
    [event] = Map.fetch!(audit_history, decision.decision_id)

    records =
      Enum.map(1..10_000, fn index ->
        decision_id = "dec-#{index}"
        created_at = DateTime.add(event.data.created_at, index, :microsecond)

        %{
          event
          | decision_id: decision_id,
            data: %{event.data | decision_id: decision_id, created_at: created_at, source_created_at: created_at}
        }
      end)

    current = Map.new(records, &{&1.decision_id, &1.data})

    decision_index =
      records
      |> Enum.map(&decision_index_key(&1.data))
      |> :gb_sets.from_list()

    retained_index = RetainedSnapshot.build_index(current)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | audit_history: Map.new(records, &{&1.decision_id, [&1]}),
          current: current,
          decision_index: decision_index,
          retained_index: retained_index,
          recent_audit: records |> Enum.reverse() |> Enum.take(50)
      }
    end)

    recent = DecisionStore.recent_audit_history(10_000, pid)

    assert length(recent.records) == 50
    assert Enum.map(recent.records, & &1.decision_id) == Enum.map(10_000..9_951//-1, &"dec-#{&1}")
    assert map_size(recent.contexts) == 50
    assert map_size(:sys.get_state(pid).audit_history) == 10_000

    payload =
      ControlCenterPresenter.state_payload(:unused, 10,
        decision_store: pid,
        fleet_fun: fn -> %{generated_at: nil, counts: %{}, analytics: nil} end,
        history_fun: fn -> [] end,
        recent_merges_fun: fn -> %{merges: [], health: :ready, reconciliation: %{}} end
      )

    assert length(payload.decisions) == 50

    assert MapSet.new(payload.decisions, & &1.decision_id) ==
             MapSet.new(10_000..9_951//-1, &"dec-#{&1}")

    assert {:ok, %{decisions: page, has_next?: true, total: 10_000, counts: %{open: 10_000, blocking: 0}}} =
             DecisionStore.retained_query(
               %{limit: 2, cursor: nil, lifecycle: nil, search: nil, ticket: nil},
               pid
             )

    assert length(page) == 2
  end

  test "resolving a cached decision backfills the untouched 51st open decision", %{dir: dir} do
    parent = self()

    dispatcher = fn _decision, opts ->
      send(parent, {:backfill_dispatch, opts[:attempt_id]})
      {:ok, %{status: :accepted, item: %{id: 51}}}
    end

    pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

    assert {:ok, %{decision: cached}} =
             request(pid, %{
               "source_id" => "cached-blocker",
               "question" => "Resolve this cached blocker?",
               "blocking" => true,
               "options" => [%{"id" => "ship", "label" => "Ship"}]
             })

    assert {:ok, %{action: action}} =
             answer(pid, cached.decision_id, %{
               "idempotency_key" => "cached-blocker-answer",
               "expected_version" => 1,
               "option_id" => "ship"
             })

    assert_receive {:backfill_dispatch, attempt_id}, 1_000
    _queued = wait_for_decision(pid, cached.decision_id, &(&1.delivery_status == :queued))
    assert {:ok, :accepted} = DecisionStore.record_delivery(correlated_queue_item(cached, action, attempt_id, 51), pid)

    untouched =
      for index <- 1..50 do
        assert {:ok, %{decision: decision}} =
                 request(pid, %{
                   "source_id" => "untouched-#{index}",
                   "question" => "Untouched open decision #{index}?",
                   "blocking" => false
                 })

        decision
      end

    assert length(DecisionStore.recent_decisions(50, pid)) == 50
    assert Enum.any?(DecisionStore.recent_decisions(50, pid), &(&1.decision_id == cached.decision_id))

    lifecycle_payload = %{
      "decision_id" => cached.decision_id,
      "action_id" => action.action_id,
      "expected_version" => 1
    }

    lifecycle_opts = [
      ticket_identifier: "979",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{agent_id: "codex", session_id: "session-1", invocation_id: "backfill-test"}
    ]

    assert {:ok, %{status: :accepted}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, lifecycle_payload, lifecycle_opts, pid)

    projected_ids = MapSet.new(DecisionStore.recent_decisions(50, pid), & &1.decision_id)
    refute MapSet.member?(projected_ids, cached.decision_id)
    assert projected_ids == MapSet.new(untouched, & &1.decision_id)
  end
end
