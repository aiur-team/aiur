defmodule Aiur.DecisionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.EventsDigest

  alias Aiur.{
    AlertFeed,
    Boot,
    Decision,
    DecisionDispatchTasks,
    DecisionEvent,
    DecisionHistory,
    DecisionLog,
    DecisionProjection,
    DecisionPubSub,
    DecisionStore,
    ExecutorCommandAttention,
    ExecutorCommandCLI
  }

  alias Aiur.DecisionEvent.Unrecognized
  alias Aiur.DecisionStore.RetainedSnapshot
  alias Aiur.Events.{Exchange, IdGenerator}
  alias AiurWeb.ControlCenterPresenter

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-store-#{System.unique_integer([:positive])}")
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

  defp start_store!(dir, opts \\ []) do
    Application.put_env(:aiur, :decision_state_dir, dir)

    start_opts =
      Keyword.merge([name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end], opts)

    {:ok, pid} = DecisionStore.start_link(start_opts)
    pid
  end

  test "unnamed stores require an explicit durable state directory" do
    assert {:error, :unnamed_store_requires_state_dir} =
             DecisionStore.start_link(filesystem_sync_fun: fn -> :ok end)
  end

  test "non-singleton stores require an explicit durable state directory" do
    custom_name = Module.concat(__MODULE__, CustomStore)

    result = DecisionStore.start_link(name: custom_name, filesystem_sync_fun: fn -> :ok end)

    case result do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end

    assert {:error, :non_singleton_store_requires_state_dir} = result
  end

  test "non-singleton stores reject invalid durable state directories" do
    custom_name = Module.concat(__MODULE__, InvalidDirectoryStore)

    for name <- [nil, custom_name, DecisionStore], state_dir <- [nil, "", :invalid] do
      assert {:error, :invalid_state_dir} =
               DecisionStore.start_link(name: name, state_dir: state_dir, filesystem_sync_fun: fn -> :ok end)
    end
  end

  test "two unnamed stores isolate their durable state", %{dir: dir} do
    first_dir = Path.join(dir, "first")
    second_dir = Path.join(dir, "second")

    if Process.whereis(IdGenerator) == nil do
      start_supervised!({IdGenerator, path: Path.join(dir, "event_id")}, id: :decision_store_test_id_generator)
    end

    {:ok, first} =
      start_supervised(
        {
          DecisionStore,
          [
            state_dir: first_dir,
            filesystem_sync_fun: fn -> :ok end
          ]
        },
        id: :first_unnamed_decision_store
      )

    {:ok, second} =
      start_supervised(
        {
          DecisionStore,
          [
            state_dir: second_dir,
            filesystem_sync_fun: fn -> :ok end
          ]
        },
        id: :second_unnamed_decision_store
      )

    assert first != second

    assert {:ok, %{decision: %{decision_id: first_id}}} =
             request(first, %{"source_id" => "first-store", "question" => "First store", "blocking" => false})

    assert {:ok, %{decision: %{decision_id: second_id}}} =
             request(second, %{"source_id" => "second-store", "question" => "Second store", "blocking" => false})

    refute first_id == second_id
    assert File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "First store"
    refute File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "Second store"
    assert File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "Second store"
    refute File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "First store"
  end

  test "custom-named stores isolate their durable state", %{dir: dir} do
    first_dir = Path.join(dir, "named-first")
    second_dir = Path.join(dir, "named-second")
    first_name = Module.concat(__MODULE__, FirstCustomStore)
    second_name = Module.concat(__MODULE__, SecondCustomStore)

    if Process.whereis(IdGenerator) == nil do
      start_supervised!({IdGenerator, path: Path.join(dir, "event_id")}, id: :custom_decision_store_test_id_generator)
    end

    {:ok, first} =
      start_supervised(
        {DecisionStore, [name: first_name, state_dir: first_dir, filesystem_sync_fun: fn -> :ok end]},
        id: :first_custom_decision_store
      )

    {:ok, second} =
      start_supervised(
        {DecisionStore, [name: second_name, state_dir: second_dir, filesystem_sync_fun: fn -> :ok end]},
        id: :second_custom_decision_store
      )

    assert {:ok, %{decision: %{decision_id: first_id}}} =
             request(first, %{"source_id" => "first-custom-store", "question" => "First custom store", "blocking" => false})

    assert {:ok, %{decision: %{decision_id: second_id}}} =
             request(second, %{"source_id" => "second-custom-store", "question" => "Second custom store", "blocking" => false})

    refute first_id == second_id
    assert File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "First custom store"
    refute File.read!(Path.join(first_dir, "decisions.ndjson")) =~ "Second custom store"
    assert File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "Second custom store"
    refute File.read!(Path.join(second_dir, "decisions.ndjson")) =~ "First custom store"
  end

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

  defp request(pid, payload, opts \\ []) do
    DecisionStore.request(payload, Keyword.merge([ticket: @ticket, source: @source], opts), pid)
  end

  test "dismiss is durable, idempotent, historic, and write-gated", %{dir: dir} do
    pid = start_store!(dir)

    # Non-blocking: dismissal closes a notice outright. A blocking Command is
    # covered separately — dismissal cannot release its agent.
    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Use blue or green?",
               "blocking" => false,
               "options" => [
                 %{"id" => "blue", "label" => "Blue"},
                 %{"id" => "green", "label" => "Green"}
               ]
             })

    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: dismissed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert dismissed.decision_status == :dismissed
    assert dismissed.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert replayed.decision_status == :dismissed

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id

    :sys.replace_state(pid, &%{&1 | writable?: false, health: {:corrupt, 1, :test}})

    assert {:error, {:store_unavailable, {:corrupt, 1, :test}}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :dismissed
  end

  test "deferral is durable, idempotent, and remains answerable", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Use the release train?", "blocking" => true})
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    assert {:ok, %{status: :accepted, decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert deferred.decision_status == :deferred
    assert deferred.answer == nil

    assert {:ok, %{status: :duplicate, decision: replayed}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert replayed.decision_status == :deferred

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :deferred

    assert {:ok, %{decision: answerable}} =
             answer(restarted, decision.decision_id, %{
               "idempotency_key" => "deferred-answer",
               "expected_version" => 1,
               "custom_response" => "Use the release train"
             })

    assert answerable.decision_status == :decided
  end

  test "operator dismissal closes a deferred legacy blocker durably", %{dir: dir} do
    pid = start_store!(dir)

    assert {:ok, %{decision: decision}} = project_attention(pid, minimal_attention("Still blocked?"))
    opts = [actor: %{kind: :operator, id: "dashboard"}]
    assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
    assert {:ok, %{status: :accepted, decision: dismissed}} = DecisionStore.dismiss(deferred.decision_id, opts, pid)
    assert dismissed.decision_status == :dismissed

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
    assert durable.decision_status == :dismissed
  end

  test "dismissal is refused for a blocking Command it cannot release", %{dir: dir} do
    pid = start_store!(dir)
    opts = [actor: %{kind: :operator, id: "dashboard"}]

    # Agent-filed: blocking, with no legacy attention to resolve alongside it.
    # Dismissal delivers nothing to the agent, so closing it would hide a live
    # block rather than clear it.
    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Push or hold?", "blocking" => true})

    assert {:error, {:conflict, :blocking_requires_answer}} =
             DecisionStore.dismiss(decision.decision_id, opts, pid)

    assert {:ok, still_open} = DecisionStore.get(decision.decision_id, pid)
    assert still_open.decision_status == :open

    # Deferring first must not open a back door to the same hidden close.
    assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)

    assert {:error, {:conflict, :blocking_requires_answer}} =
             DecisionStore.dismiss(deferred.decision_id, opts, pid)

    # Answering is the path that actually releases the agent.
    assert {:ok, %{decision: answered}} =
             answer(pid, decision.decision_id, %{
               "idempotency_key" => "blocking-answer",
               "expected_version" => 1,
               "custom_response" => "Hold the push"
             })

    assert answered.decision_status == :decided
  end

  describe "blocked_ticket_ids/1 (#1965)" do
    test "returns ticket identifiers with open blocking Commands only", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: blocking}} =
               request(
                 pid,
                 %{"question" => "Open a blocker?", "blocking" => true},
                 ticket: %{@ticket | identifier: "11"}
               )

      assert {:ok, %{decision: non_blocking}} =
               request(
                 pid,
                 %{"question" => "Notice only?", "blocking" => false},
                 ticket: %{@ticket | identifier: "22"}
               )

      non_blocking_id = non_blocking.decision_id

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new(["11"])

      # Answering the blocker releases the ticket on the next read.
      assert {:ok, %{status: :accepted}} =
               answer(pid, blocking.decision_id, %{
                 "idempotency_key" => "answer-blocker",
                 "expected_version" => blocking.version,
                 "custom_response" => "Proceed"
               })

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new()

      # The non-blocking Command is untouched (it was never in the set).
      assert {:ok, %Decision{decision_id: ^non_blocking_id}} =
               DecisionStore.get(non_blocking_id, pid)
    end

    test "a deferred blocking Command still gates dispatch until answered", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(
                 pid,
                 %{"question" => "Defer this blocker?", "blocking" => true},
                 ticket: %{@ticket | identifier: "33"}
               )

      assert {:ok, %{decision: deferred}} =
               DecisionStore.defer(decision.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)

      assert deferred.decision_status == :deferred
      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "33")

      assert {:ok, %{decision: answered}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "answer-deferred-blocker",
                 "expected_version" => 1,
                 "custom_response" => "Proceed"
               })

      assert answered.decision_status == :decided
      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      refute MapSet.member?(ids, "33")
    end

    test "option-less legacy attentions never gate dispatch, but real blockers do", %{dir: dir} do
      pid = start_store!(dir)
      slug = "decision-delivery-act-1"

      assert {:ok, %{status: :accepted, decision: delivery_alert}} =
               DecisionStore.project_attention(
                 %{
                   "question" => "Decision action remains actionable after turn_failed.",
                   "blocking" => true,
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:#{slug}"
                 },
                 [
                   ticket: @ticket,
                   source: @source,
                   legacy_attention: %{slug: slug, topic: "ticket.979.agent.attention.#{slug}"}
                 ],
                 pid
               )

      assert delivery_alert.blocking

      # #1844: an option-less legacy attention does not gate dispatch either,
      # even when the persisted record still says `blocking: true` — records
      # written before attentions were filed unblocking are still in the store,
      # and each one would otherwise hold the whole ticket's dispatch.
      assert {:ok, %{status: :accepted, decision: attention}} =
               project_attention(pid, minimal_attention("Which owner should take this?"))

      assert attention.blocking
      assert attention.options == []

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert ids == MapSet.new()

      # A real agent-filed blocking Command on the same ticket still gates it,
      # so the exclusion is scoped to attentions rather than disarming the gate.
      assert {:ok, %{decision: _blocker}} =
               request(pid, %{"question" => "Drop the index?", "blocking" => true})

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "979")
    end

    test "fails closed when the store cannot be read", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: _decision}} = request(pid, %{"question" => "Block?", "blocking" => true})

      :sys.replace_state(pid, &%{&1 | writable?: false, health: {:unavailable, :test}})
      assert {:error, :store_unavailable} = DecisionStore.blocked_ticket_ids(pid)

      GenServer.stop(pid)
      assert {:error, :store_unavailable} = DecisionStore.blocked_ticket_ids(pid)
    end
  end

  describe "supersede-and-clear on answer (#1844)" do
    test "answering a Command clears its open duplicates on the same ticket", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should PR #1820 push its existing merge?"

      assert {:ok, %{decision: primary}} =
               request(pid, %{
                 "question" => question,
                 "blocking" => false,
                 "options" => [
                   %{"id" => "push_refresh", "label" => "Push the refresh"},
                   %{"id" => "keep_unpushed", "label" => "Keep it unpushed"}
                 ]
               })

      # The same question filed a second time as an option-less attention —
      # the exact #1844 shape. `source_id` differs, so nothing dedups it today;
      # it is filed by a *different* agent so creation-time dedup (#2099) does
      # not collapse it before the answer-time supersede can be exercised.
      assert {:ok, %{status: :accepted, decision: duplicate}} =
               project_attention(
                 pid,
                 %{
                   "question" => "  SHOULD PR #1820 push its existing `merge`.  ",
                   "blocking" => false,
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:push-question"
                 },
                 source: %{@source | agent_id: "agent-2"}
               )

      # A genuinely different question on the same ticket, and the same question
      # on a different ticket. Neither may be swept up.
      assert {:ok, %{decision: unrelated}} =
               request(pid, %{"question" => "Should we drop the index?", "blocking" => false})

      assert {:ok, %{decision: other_ticket}} =
               request(pid, %{"question" => question, "blocking" => false}, ticket: %{@ticket | identifier: "5150"})

      assert duplicate.decision_status == :open

      assert {:ok, %{status: :accepted}} =
               answer(pid, primary.decision_id, %{
                 "idempotency_key" => "answer-primary",
                 "expected_version" => primary.version,
                 "option_id" => "push_refresh"
               })

      assert {:ok, %Decision{decision_status: :dismissed} = cleared} =
               DecisionStore.get(duplicate.decision_id, pid)

      # The dismissal names the Command that answered it, so the audit trail
      # explains why a record the operator never touched closed itself.
      assert {:ok, audit} = DecisionStore.audit_history(cleared.decision_id, pid)

      assert Enum.any?(audit, fn record ->
               match?(%DecisionEvent{type: :decision_dismissed}, record) and
                 record.data.actor.id == "superseded-by:#{primary.decision_id}"
             end)

      assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(unrelated.decision_id, pid)
      assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(other_ticket.decision_id, pid)
    end

    test "an agent-filed blocking duplicate is never silently cleared", %{dir: dir} do
      pid = start_store!(dir)
      question = "Which owner should take this?"

      assert {:ok, %{decision: primary}} =
               request(pid, %{"question" => question, "blocking" => false})

      # Blocking, agent-filed, no legacy attention: `unresolvable_block?/1`
      # refuses dismissal because it would release nothing to the waiting agent.
      # Superseding must respect that rather than route around it.
      assert {:ok, %{decision: blocking_twin}} =
               request(pid, %{"question" => question, "blocking" => true})

      assert {:ok, %{status: :accepted}} =
               answer(pid, primary.decision_id, %{
                 "idempotency_key" => "answer-owner",
                 "expected_version" => primary.version,
                 "custom_response" => "Platform owns it"
               })

      assert {:ok, %Decision{decision_status: :open}} =
               DecisionStore.get(blocking_twin.decision_id, pid)

      assert {:ok, ids} = DecisionStore.blocked_ticket_ids(pid)
      assert MapSet.member?(ids, "979")
    end
  end

  test "expiration is durable, idempotent, historic, and auditable", %{dir: dir} do
    pid = start_store!(dir)
    created_at = ~U[2026-07-24 12:00:00Z]
    expired_at = DateTime.add(created_at, 600, :second)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Still waiting?", "blocking" => true}, now: created_at)

    assert {:ok, %{status: :accepted, decision: expired}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [now: expired_at], pid)

    assert expired.decision_status == :expired
    assert expired.answer == nil

    assert {:ok, %{status: :duplicate, decision: duplicate}} =
             DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)

    assert duplicate.decision_status == :expired

    answer_payload = %{"idempotency_key" => "too-late", "expected_version" => 1, "custom_response" => "Ship"}
    assert {:error, {:conflict, :expired}} = answer(pid, decision.decision_id, answer_payload)

    assert {:ok, %{decisions: [historic], total: 1}} =
             DecisionStore.retained_query(
               %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
               pid
             )

    assert historic.decision_id == decision.decision_id

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

    assert [
             %DecisionEvent{type: :requested},
             %DecisionEvent{type: :decision_expired, data: %{reason_class: "agent_not_running"}}
           ] = audit

    GenServer.stop(pid)
    restarted = start_store!(dir)
    assert {:ok, replayed} = DecisionStore.get(decision.decision_id, restarted)
    assert replayed.decision_status == :expired
  end

  describe "moot disposition (#2099)" do
    test "retires an open Command with a recorded reason and no answer", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Reclassify #2071?", "blocking" => true})

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{
                   "reason_class" => "ticket_closed",
                   "reason" => "Ticket #2071 was folded into #2073."
                 },
                 [actor: %{kind: :operator, id: "dashboard"}],
                 pid
               )

      assert mooted.decision_status == :moot
      assert mooted.answer == nil

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)

      assert [
               %DecisionEvent{type: :requested},
               %DecisionEvent{
                 type: :decision_mooted,
                 data: %{
                   reason_class: "ticket_closed",
                   detail: "Ticket #2071 was folded into #2073.",
                   actor: %{kind: :operator, id: "dashboard"}
                 }
               }
             ] = audit

      # Distinguishable from a real answer: the Command is not decided, and the
      # audit record carries an actor + reason, never a DecisionAnswer.
      assert {:error, {:conflict, :moot}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "too-late",
                 "expected_version" => 1,
                 "custom_response" => "Ship"
               })
    end

    test "moot is durable, idempotent, and historic", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Defer or close?", "blocking" => true})
      opts = [actor: %{kind: :operator, id: "dashboard"}]
      assert {:ok, %{decision: deferred}} = DecisionStore.defer(decision.decision_id, opts, pid)
      assert deferred.decision_status == :deferred

      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "origin_agent_gone"}, opts, pid)

      assert mooted.decision_status == :moot

      assert {:ok, %{status: :duplicate, decision: duplicate}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "origin_agent_gone"}, opts, pid)

      assert duplicate.decision_status == :moot

      assert {:ok, %{decisions: [historic], total: 1}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :historic, search: nil, ticket: nil},
                 pid
               )

      assert historic.decision_id == decision.decision_id

      # A mooted Command leaves the open surface entirely.
      assert {:ok, %{decisions: [], total: 0}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, search: nil, ticket: nil},
                 pid
               )

      GenServer.stop(pid)
      restarted = start_store!(dir)
      assert {:ok, durable} = DecisionStore.get(decision.decision_id, restarted)
      assert durable.decision_status == :moot
    end

    test "a blocking human_required legacy Command about a closed ticket is retirable", %{dir: dir} do
      pid = start_store!(dir)

      # The exact #2099 daemon shape: legacy_attention, blocking, human_required.
      assert {:ok, %{status: :accepted, decision: decision}} =
               DecisionStore.project_attention(
                 %{
                   "question" => "Should ticket #2071 be reclassified for fresh implementation?",
                   "blocking" => true,
                   "authority" => "human_required",
                   "reversibility" => "irreversible",
                   "kind" => "legacy_attention",
                   "source_id" => "legacy_attention:2071-reclassify"
                 },
                 [
                   ticket: @ticket,
                   source: %{agent_id: "codex", session_id: nil, event_id: nil},
                   legacy_attention: %{slug: "2071-reclassify", topic: "ticket.979.agent.attention.2071-reclassify"}
                 ],
                 pid
               )

      assert decision.blocking
      assert decision.authority == :human_required
      assert decision.decision_status == :open

      # `executor-answer` is refused by the floor for this Command…
      assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "executor-try",
                   "expected_version" => 1,
                   "custom_response" => "Reclassify"
                 },
                 [actor: %{kind: :executor, id: "aiur-cli"}],
                 pid
               )

      # …and it sits in the open blocking surface (R4: `commands --blocking`).
      assert {:ok, %{decisions: [open_blocker], total: 1}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, blocking: true, search: nil, ticket: nil},
                 pid
               )

      assert open_blocker.decision_id == decision.decision_id

      # Moot is the disposition for a question that is void: it retires the
      # Command — and the block with it — recording why and by whom, with no
      # answer fabricated.
      assert {:ok, %{status: :accepted, decision: mooted}} =
               DecisionStore.moot(
                 decision.decision_id,
                 %{
                   "reason_class" => "ticket_closed",
                   "reason" => "Ticket #2071 was folded into #2073."
                 },
                 [actor: %{kind: :operator, id: "dashboard"}],
                 pid
               )

      assert mooted.decision_status == :moot
      assert mooted.answer == nil

      # The blocking surface reports only Commands a human genuinely still needs.
      assert {:ok, %{decisions: [], total: 0}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: :open, blocking: true, search: nil, ticket: nil},
                 pid
               )

      assert {:ok, %{counts: %{blocking: 0, open: 0}}} =
               DecisionStore.retained_counts(pid)
    end

    test "moot requires a reason class and is write-gated", %{dir: dir} do
      pid = start_store!(dir)
      opts = [actor: %{kind: :operator, id: "dashboard"}]
      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Void?", "blocking" => false})

      assert {:error, {:moot_invalid, {:reason_class, :missing}}} =
               DecisionStore.moot(decision.decision_id, %{}, opts, pid)

      :sys.replace_state(pid, &%{&1 | writable?: false, health: {:corrupt, 1, :test}})

      assert {:error, {:store_unavailable, {:corrupt, 1, :test}}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, opts, pid)
    end

    test "moot is refused for a Command that already has an answer", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Push or hold?",
                 "blocking" => false,
                 "options" => [%{"id" => "push", "label" => "Push"}]
               })

      assert {:ok, %{decision: answered}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "answer",
                 "expected_version" => 1,
                 "option_id" => "push"
               })

      assert answered.decision_status == :decided

      assert {:error, {:conflict, :decided}} =
               DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, [actor: %{kind: :operator, id: "dashboard"}], pid)
    end
  end

  describe "creation-time dedup (#2099)" do
    test "two same-agent, same-ticket, same-window, same-question Commands create one", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should PR #1820 push its existing merge?"

      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{"question" => question, "blocking" => false})

      assert {:ok, %{status: :duplicate, decision: duplicate}} =
               request(pid, %{"question" => question, "blocking" => false})

      assert duplicate.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 1
    end

    test "paraphrases of one question from the same agent collapse within the window", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{
                 "question" => "Should ticket #2071 be reclassified for fresh implementation, or should the missing prior PR/ref and review feedback be restored first?",
                 "blocking" => false,
                 "source_id" => "q1"
               })

      assert {:ok, %{status: :duplicate, decision: second}} =
               request(pid, %{
                 "question" => "Ticket #2071 has no prior PR/ref or review feedback; choose fresh implementation or artifact restoration",
                 "blocking" => false,
                 "source_id" => "q2"
               })

      assert {:ok, %{status: :duplicate, decision: third}} =
               request(pid, %{
                 "question" => "Reclassify #2071 for fresh implementation, or restore the missing prior PR/ref and review feedback?",
                 "blocking" => false,
                 "source_id" => "q3"
               })

      # All three collapse to the first Command.
      assert second.decision_id == first.decision_id
      assert third.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 1
    end

    test "a different agent or ticket does not collapse", %{dir: dir} do
      pid = start_store!(dir)
      question = "Should we drop the index?"

      assert {:ok, %{decision: agent_a}} = request(pid, %{"question" => question, "blocking" => false})

      assert {:ok, %{decision: agent_b}} =
               request(pid, %{"question" => question, "blocking" => false}, source: %{@source | agent_id: "agent-2"})

      assert {:ok, %{decision: other_ticket}} =
               request(pid, %{"question" => question, "blocking" => false}, ticket: %{@ticket | identifier: "5150"})

      refute agent_b.decision_id == agent_a.decision_id
      refute other_ticket.decision_id == agent_a.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 3
    end

    test "an answered Command is not a dedup candidate for a new similar one", %{dir: dir} do
      pid = start_store!(dir)
      question = "Which owner should take this?"

      assert {:ok, %{decision: first}} =
               request(pid, %{"question" => question, "blocking" => false, "source_id" => "first"})

      assert {:ok, %{status: :accepted, decision: decided}} =
               answer(pid, first.decision_id, %{
                 "idempotency_key" => "answer",
                 "expected_version" => 1,
                 "custom_response" => "Platform"
               })

      assert decided.decision_status == :decided

      # A decided Command no longer represents an open question, so a fresh
      # similar Command from the same agent creates its own row.
      assert {:ok, %{status: :accepted, decision: fresh}} =
               request(pid, %{
                 "question" => question,
                 "blocking" => false,
                 "source_id" => "fresh",
                 now: DateTime.add(DateTime.utc_now(), 5, :second)
               })

      refute fresh.decision_id == first.decision_id
      assert fresh.decision_status == :open
    end

    test "attention projections dedup against a recent same-agent Command", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: first}} =
               request(pid, %{
                 "question" => "Should ticket #2071 be reclassified for fresh implementation?",
                 "blocking" => false,
                 "source_id" => "agent-request"
               })

      assert {:ok, %{status: :duplicate, decision: duplicate}} =
               project_attention(pid, %{
                 "question" => "Reclassify ticket #2071 for fresh implementation?",
                 "blocking" => false,
                 "kind" => "legacy_attention",
                 "source_id" => "legacy_attention:2071-reclassify"
               })

      assert duplicate.decision_id == first.decision_id

      assert decisions = DecisionStore.list(pid)
      assert length(decisions) == 1
    end
  end

  defp decision_index_key(decision) do
    urgency = %{low: 0, normal: 1, high: 2, critical: 3}

    {
      decision.decision_status in [:expired, :dismissed, :resolved],
      not decision.blocking,
      -Map.fetch!(urgency, decision.urgency),
      -DateTime.to_unix(decision.created_at, :microsecond),
      decision.decision_id
    }
  end

  defp project_attention(pid, payload, opts \\ []) do
    DecisionStore.project_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  defp enrich_attention(pid, payload, opts) do
    DecisionStore.enrich_attention(
      payload,
      Keyword.merge([ticket: @ticket, source: @source, legacy_attention: legacy_attention()], opts),
      pid
    )
  end

  defp legacy_attention do
    %{
      slug: "scope-question",
      topic: "ticket.979.agent.attention.scope-question"
    }
  end

  defp minimal_attention(question \\ "Which scope should own this?") do
    %{
      "question" => question,
      "blocking" => true,
      "kind" => "legacy_attention",
      "source_id" => "legacy_attention:scope-question"
    }
  end

  defp answer(pid, decision_id, payload, opts \\ []) do
    DecisionStore.answer(
      decision_id,
      payload,
      Keyword.merge([actor: %{kind: :operator, id: "operator-1"}], opts),
      pid
    )
  end

  defp dispatch_fence_size({:dispatch_action, fence, false}),
    do: fence |> :erlang.term_to_binary() |> byte_size()

  defp enrich(pid, decision_id, patch, expected_version, opts \\ []) do
    DecisionStore.enrich(
      decision_id,
      patch,
      Keyword.merge(
        [
          actor: %{kind: :supervisor, id: "supervising-agent"},
          expected_version: expected_version,
          now: ~U[2026-07-12 11:00:00Z]
        ],
        opts
      ),
      pid
    )
  end

  describe "happy path" do
    test "accepts a fresh request as version 1", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: decision}} =
               request(pid, %{"question" => "Deploy now?", "blocking" => true})

      assert decision.version == 1
      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
      assert DecisionStore.list(pid) == [decision]
      assert {:ok, [^decision]} = DecisionStore.history(decision.decision_id, pid)
      assert DecisionStore.all_history(pid) == %{decision.decision_id => [decision]}

      assert {:ok, [%DecisionEvent{type: :requested, data: ^decision}]} =
               DecisionStore.audit_history(decision.decision_id, pid)
    end

    test "returns a bounded recent audit window with only its projection contexts", %{dir: dir} do
      pid = start_store!(dir, dispatch_delay_ms: 60_000)

      assert {:ok, %{decision: contextual}} =
               request(pid, %{
                 "source_id" => "recent-audit-context",
                 "question" => "Does a bounded lifecycle event retain its context?",
                 "blocking" => true,
                 "options" => [%{"id" => "yes", "label" => "Yes"}]
               })

      for index <- 1..55 do
        assert {:ok, _result} =
                 request(pid, %{
                   "source_id" => "recent-audit-#{index}",
                   "question" => "Recent decision #{index}?",
                   "blocking" => false
                 })
      end

      assert %{records: records, contexts: contexts, revisions: %{}} =
               DecisionStore.recent_audit_history(5, pid)

      assert Enum.map(records, & &1.data.source_id) ==
               Enum.map(55..51//-1, &"recent-audit-#{&1}")

      assert map_size(contexts) == 5
      assert %{records: capped} = DecisionStore.recent_audit_history(500, pid)
      assert length(capped) == 50
      assert Enum.any?(DecisionStore.recent_decisions(50, pid), &(&1.decision_id == contextual.decision_id))

      assert {:ok, _answer_result} =
               answer(pid, contextual.decision_id, %{
                 "idempotency_key" => "recent-audit-answer",
                 "expected_version" => contextual.version,
                 "option_id" => "yes"
               })

      assert [answered] = DecisionHistory.list(server: pid, limit: 1)
      assert answered.change == :answered
      assert answered.question == "Does a bounded lifecycle event retain its context?"

      GenServer.stop(pid)
      replayed = start_store!(dir, dispatch_delay_ms: 60_000)
      assert [replayed_answer] = DecisionHistory.list(server: replayed, limit: 1)
      assert replayed_answer.question == answered.question
    end

    test "new request audit records carry the typed envelope and canonical run id", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Deploy now?", "blocking" => true})

      [record] =
        dir
        |> Path.join("decisions.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert record["event_type"] == "requested"
      assert record["run_id"] == Boot.run_id()
      assert "decision-provenance-v1:" <> reserved_event_id = record["event_id"]
      assert {reserved_id, ""} = Integer.parse(reserved_event_id)
      assert reserved_id > 0
      assert record["data"]["decision_id"] == decision.decision_id
    end

    test "the audit log and the projection file are both owner-only after an accept", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, _} = request(pid, %{"question" => "Deploy now?", "blocking" => true})

      for filename <- ["decisions.ndjson", "decisions.json"] do
        %File.Stat{mode: mode} = File.stat!(Path.join(dir, filename))
        assert Bitwise.band(mode, 0o777) == 0o600
      end
    end

    test "runs the filesystem barrier during startup rather than the first request", %{dir: dir} do
      test_pid = self()

      sync_fun = fn ->
        send(test_pid, :filesystem_synced)
        :ok
      end

      pid = start_store!(dir, filesystem_sync_fun: sync_fun)

      assert_receive :filesystem_synced, 2_000
      refute_receive :filesystem_synced

      assert {:ok, _} = request(pid, %{"question" => "Deploy now?", "blocking" => true})
      refute_receive :filesystem_synced
    end

    test "redacts ticket and artifact credentials before either durable file is written", %{dir: dir} do
      pid = start_store!(dir)
      secret = "GHSAT0" <> String.duplicate("A", 36)

      ticket = %{
        identifier: "979",
        title: "Leaked #{secret}",
        url: "https://github.com/its-everdred/aiur/issues/979?token=#{secret}"
      }

      payload = %{
        "question" => "Inspect the artifact?",
        "blocking" => true,
        "artifacts" => ["https://raw.githubusercontent.com/org/repo/main/file?token=#{secret}"]
      }

      assert {:ok, %{status: :accepted}} = request(pid, payload, ticket: ticket)

      for filename <- ["decisions.ndjson", "decisions.json"] do
        persisted = File.read!(Path.join(dir, filename))
        refute persisted =~ secret
        assert persisted =~ "[REDACTED:ghsat]"
      end
    end

    test "an unknown decision_id returns :not_found", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, :not_found} = DecisionStore.get("dec_missing", pid)
      assert {:error, :not_found} = DecisionStore.history("dec_missing", pid)
    end
  end

  describe "dedup and versioning" do
    test "an exact replay of the current version and content is a duplicate, not a new append", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: first}} = request(pid, payload)
      assert {:ok, %{status: :duplicate, decision: second}} = request(pid, payload)

      assert first.decision_id == second.decision_id
      assert {:ok, [^first]} = DecisionStore.history(first.decision_id, pid)
    end

    test "changed content re-arms a dismissed Command that is not a legacy attention", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Roll the index?", "blocking" => false, "source_id" => "rearm-1"}

      assert {:ok, %{decision: v1}} = request(pid, base)
      refute v1.legacy_attention

      assert {:ok, %{decision: dismissed}} =
               DecisionStore.dismiss(v1.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)

      assert dismissed.decision_status == :dismissed

      # The operator closed this against evidence that no longer exists, so the
      # re-file must bring it back — the same guarantee a legacy attention gets.
      assert {:ok, %{decision: rearmed}} =
               request(pid, Map.merge(base, %{"question" => "Roll the index after the backfill?", "version" => 2}))

      assert rearmed.decision_id == v1.decision_id
      assert rearmed.decision_status == :open
      assert rearmed.delivery_status == :not_dispatched
    end

    test "the next version with different content is accepted as an enrichment", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: v1}} = request(pid, base)

      v2_payload = Map.merge(base, %{"question" => "Deploy now, revised?", "version" => 2})
      assert {:ok, %{status: :accepted, decision: v2}} = request(pid, v2_payload)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
      assert DecisionStore.all_history(pid)[v1.decision_id] == [v1, v2]
      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
    end

    test "same version, different content is an idempotency conflict", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)

      conflicting = Map.put(base, "question", "Deploy now, but different?")
      assert {:error, {:conflict, {:idempotency_conflict, 1}}} = request(pid, conflicting)
    end

    test "a stale version is rejected", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)
      assert {:ok, _} = request(pid, Map.merge(base, %{"question" => "v2", "version" => 2}))

      stale = Map.merge(base, %{"question" => "v1 again", "version" => 1})
      assert {:error, {:conflict, {:stale_version, 1, 2}}} = request(pid, stale)

      way_stale = Map.merge(base, %{"question" => "v0?", "version" => 0})
      assert {:error, {:version, :invalid_type}} = request(pid, way_stale)
    end

    test "a version gap is rejected", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, base)

      gapped = Map.merge(base, %{"question" => "v3?", "version" => 3})
      assert {:error, {:conflict, {:version_gap, 3, 1}}} = request(pid, gapped)
    end

    test "a fresh decision_id requested at a version other than 1 is a version gap", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Q?", "blocking" => true, "version" => 2}
      assert {:error, {:conflict, {:version_gap, 2, nil}}} = request(pid, payload)
    end
  end

  describe "supervisor enrichment" do
    test "persists attributed enrichment before notification and survives restart", %{dir: dir} do
      pid1 = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid1, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-enrichment",
                 "kind" => "architecture",
                 "authority" => "supervisor_allowed",
                 "reversibility" => "reversible"
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      patch = %{"context" => %{"short_summary" => "Use the canonical store"}}

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich(pid1, v1.decision_id, patch, 1)

      assert v2.version == 2
      assert v2.created_at == v1.created_at
      assert v2.context.short_summary == "Use the canonical store"

      assert {:ok, [^v1, history_v2]} = DecisionStore.history(v1.decision_id, pid1)
      assert history_v2.version == 2

      assert {:ok, [requested, enriched]} = DecisionStore.audit_history(v1.decision_id, pid1)
      assert audit_type(requested) == :requested
      assert %DecisionEvent{type: :enriched, data: data} = enriched
      assert data.actor == %{kind: :supervisor, id: "supervising-agent"}
      assert data.expected_version == 1
      assert data.decision.version == 2

      assert_receive {:event,
                      %{
                        "event_id" => "decision-provenance-v1:" <> reserved_event_id,
                        topic: "ticket.979.agent.decision.enriched",
                        id: cursor_event_id
                      }},
                     500

      assert cursor_event_id > 0
      assert reserved_event_id == Integer.to_string(cursor_event_id)
      assert_receive {:decision_changed, decision_id, 2}, 500
      assert decision_id == v1.decision_id

      persisted = File.read!(Path.join(dir, "decisions.ndjson"))
      assert persisted =~ ~s("event_type":"enriched")

      GenServer.stop(pid1)
      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(v1.decision_id, pid2)
      assert replayed.version == 2
      assert replayed.context.short_summary == "Use the canonical store"
    end

    test "a non-durable enrichment ID reservation appends nothing", %{dir: dir} do
      pid = start_store!(dir, event_id_reserver: fn -> {:error, :not_durable} end)
      assert {:ok, %{decision: v1}} = request(pid, minimal_attention())

      patch = %{"context" => %{"short_summary" => "Must remain durable"}}
      assert {:error, :event_id_not_durable} = enrich(pid, v1.decision_id, patch, 1)

      assert {:ok, ^v1} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [requested]} = DecisionStore.audit_history(v1.decision_id, pid)
      assert audit_type(requested) == :requested
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 1
    end

    test "exact replay is duplicate while changed reuse conflicts without append or notification", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: v1}} =
               request(pid, %{
                 "question" => "Which architecture?",
                 "blocking" => true,
                 "source_id" => "supervisor-replay"
               })

      patch = %{"context" => %{"short_summary" => "Canonical"}}
      assert {:ok, %{status: :accepted, decision: accepted}} = enrich(pid, v1.decision_id, patch, 1)

      :ok = Exchange.subscribe("ticket.979.agent.decision.enriched")
      :ok = DecisionPubSub.subscribe()

      assert {:ok, %{status: :duplicate, decision: duplicate}} = enrich(pid, v1.decision_id, patch, 1)
      assert duplicate.version == accepted.version

      changed = %{"context" => %{"short_summary" => "Different"}}

      assert {:error, {:conflict, {:idempotency_conflict, 1}}} =
               enrich(pid, v1.decision_id, changed, 1)

      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :enriched]
      refute_receive {:event, %{topic: "ticket.979.agent.decision.enriched"}}, 100
      refute_receive {:decision_changed, _, _}, 100
      assert length(String.split(File.read!(Path.join(dir, "decisions.ndjson")), "\n", trim: true)) == 2
    end

    test "a stale historical base with no matching enrichment appends nothing", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Original?", "blocking" => true, "source_id" => "supervisor-stale"}
      assert {:ok, %{decision: v1}} = request(pid, base)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Updated?", "version" => 2}))

      assert {:error, {:conflict, {:stale_version, 1, 2}}} =
               enrich(pid, v1.decision_id, %{"context" => %{"short_summary" => "Stale"}}, 1)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "enrichment after an answer preserves its lifecycle and never redispatches", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:dispatched, :counters.get(dispatches, 1)})
        {:ok, %{status: :accepted, item: %{id: 101}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000

      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-after-answer"))

      answer_payload = %{
        "idempotency_key" => "answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, scheduled_dispatch, 0}, 2_000
      assert match?({:dispatch_action, _fence, false}, scheduled_dispatch)
      send(pid, scheduled_dispatch)
      assert_receive {:dispatched, 1}, 2_000
      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))

      GenServer.stop(pid)
      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Additional context"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(
                 replayed_pid,
                 v1.decision_id,
                 patch,
                 1
               )

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :queued
      assert enriched.dispatch_attempts == settled.dispatch_attempts

      assert {:ok, %{status: :duplicate, decision: replayed}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert replayed.answer == accepted
      assert replayed.delivery_status == :queued
      assert replayed.dispatch_attempts == settled.dispatch_attempts

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      refute_receive {:dispatch_scheduled, ^replayed_pid, _message, _delay_ms}, 100
      refute_receive {:dispatched, 2}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "pending first delivery survives enrichment before restart reconciliation", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])
      release_scheduled_work = :atomics.new(1, [])

      dispatcher = fn decision, _opts ->
        :counters.add(dispatches, 1, 1)
        send(parent, {:pending_dispatched, :counters.get(dispatches, 1), decision.version})
        {:ok, %{status: :accepted, item: %{id: 102}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})

        if :atomics.get(release_scheduled_work, 1) == 1,
          do: send(recipient, message)

        make_ref()
      end

      store_opts = [
        dispatcher: dispatcher,
        dispatch_delay_ms: 0,
        reconcile_delay_ms: 0,
        dispatch_scheduler: dispatch_scheduler
      ]

      pid = start_store!(dir, store_opts)
      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: v1}} = request(pid, answerable_request("enrich-pending-answer"))

      answer_payload = %{
        "idempotency_key" => "pending-answer-before-enrichment",
        "expected_version" => 1,
        "option_id" => "ship"
      }

      assert {:ok, %{action: accepted}} = answer(pid, v1.decision_id, answer_payload)
      assert_receive {:dispatch_scheduled, ^pid, {:dispatch_action, _fence, false}, 0}, 2_000
      GenServer.stop(pid)

      replayed_pid = start_store!(dir, store_opts)

      assert_receive {:dispatch_scheduled, ^replayed_pid, {:reconcile_dispatches, [%{request_version: 1}]} = scheduled_reconciliation, 0},
                     2_000

      patch = %{"context" => %{"short_summary" => "Context before first delivery"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(replayed_pid, v1.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.answer == accepted
      assert enriched.delivery_status == :pending
      assert enriched.dispatch_attempts == []

      :atomics.put(release_scheduled_work, 1, 1)
      send(replayed_pid, scheduled_reconciliation)

      assert_receive {:pending_dispatched, 1, 1}, 2_000
      settled = wait_for_decision(replayed_pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer == accepted
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:queued]
      refute_receive {:pending_dispatched, 2, _version}, 100
      assert :counters.get(dispatches, 1) == 1
    end

    test "dispatch lifecycle fences stay bounded across repeated retries", %{dir: dir} do
      parent = self()
      attempts = :counters.new(1, [])

      dispatcher = fn _decision, _opts ->
        :counters.add(attempts, 1, 1)
        send(parent, {:dispatch_attempted, :counters.get(attempts, 1)})
        {:error, :unavailable}
      end

      scheduler = fn recipient, message, delay_ms ->
        send(parent, {:dispatch_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: List.duplicate(0, 25),
          dispatch_scheduler: scheduler
        )

      assert_receive {:dispatch_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("bounded-dispatch-fence"))

      payload = %{"idempotency_key" => "bounded-fence", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:dispatch_scheduled, ^pid, initial_dispatch, 0}, 2_000
      send(pid, initial_dispatch)
      assert_receive {:dispatch_attempted, 1}, 2_000
      assert_receive {:dispatch_scheduled, ^pid, first_retry, 0}, 2_000

      baseline_size = dispatch_fence_size(first_retry)

      sizes =
        Enum.reduce(2..20, {first_retry, [baseline_size]}, fn attempt, {scheduled, sizes} ->
          send(pid, scheduled)
          assert_receive {:dispatch_attempted, ^attempt}, 2_000
          assert_receive {:dispatch_scheduled, ^pid, next_retry, 0}, 2_000
          {next_retry, [dispatch_fence_size(next_retry) | sizes]}
        end)
        |> elem(1)

      assert Enum.max(sizes) <= baseline_size + 64
      assert :counters.get(attempts, 1) == 20
    end
  end

  describe "legacy attention projection and enrichment" do
    test "internal delivery alerts never appear as operator Commands", %{dir: dir} do
      pid = start_store!(dir)
      slug = "decision-delivery-act-1"

      payload = %{
        "question" => "Decision action remains actionable after turn_failed.",
        "blocking" => true,
        "kind" => "legacy_attention",
        "source_id" => "legacy_attention:#{slug}"
      }

      assert {:ok, %{status: :accepted, decision: decision}} =
               DecisionStore.project_attention(
                 payload,
                 [
                   ticket: @ticket,
                   source: @source,
                   legacy_attention: %{
                     slug: slug,
                     topic: "ticket.979.agent.attention.#{slug}"
                   }
                 ],
                 pid
               )

      assert {:ok, %{decisions: [], total: 0, counts: %{open: 0, blocking: 0}}} =
               DecisionStore.retained_query(
                 %{limit: 25, cursor: nil, lifecycle: nil, search: nil, ticket: nil},
                 pid
               )

      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
    end

    test "a minimal attention creates one custom-response-only Decision", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: decision}} =
               project_attention(pid, minimal_attention())

      assert decision.version == 1
      assert decision.blocking
      assert decision.kind == "legacy_attention"
      assert decision.options == []
      assert decision.legacy_attention == legacy_attention()
      assert DecisionStore.list(pid) == [decision]
      assert {:ok, [^decision]} = DecisionStore.history(decision.decision_id, pid)
    end

    test "a structured request enriches the same Decision and exact retries do not append", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{status: :accepted, decision: v1}} =
               project_attention(pid, minimal_attention())

      structured = %{
        "question" => "Which scope should own this?",
        "blocking" => true,
        "kind" => "architecture",
        "source_id" => "legacy_attention:scope-question",
        "context" => %{"short_summary" => "Two owners are viable."},
        "options" => [
          %{"id" => "facade", "label" => "Facade"},
          %{"id" => "runtime", "label" => "Runtime"}
        ],
        "recommendation" => %{"option_id" => "runtime", "reason" => "Owns the state."}
      }

      source_v2 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"}

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: source_v2)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert length(v2.options) == 2
      assert DecisionStore.list(pid) == [v2]

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, structured, source: source_v2)

      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a retried structured action deduplicates after a later version advances", %{dir: dir} do
      pid = start_store!(dir)

      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      v2_payload =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "First enrichment"})

      source_v2 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"}
      assert {:ok, %{status: :accepted, decision: v2}} = enrich_attention(pid, v2_payload, source: source_v2)

      v3_payload = Map.put(v2_payload, "context", %{"short_summary" => "Second enrichment"})
      source_v3 = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-3"}
      assert {:ok, %{status: :accepted, decision: v3}} = enrich_attention(pid, v3_payload, source: source_v3)

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, v2_payload, source: source_v2)

      assert {:ok, ^v3} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "the same protocol call id in a new session is a distinct enrichment action", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      first =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "First session"})

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, first, source: %{agent_id: "agent-1", session_id: "session-a", event_id: "call-2"})

      second = Map.put(first, "context", %{"short_summary" => "Second session"})

      assert {:ok, %{status: :accepted, decision: v3}} =
               enrich_attention(pid, second, source: %{agent_id: "agent-1", session_id: "session-b", event_id: "call-2"})

      assert v3.version == 3
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a retried legacy action deduplicates after structured enrichment", %{dir: dir} do
      pid = start_store!(dir)
      legacy_source = %{agent_id: "agent-1", session_id: "session-1", event_id: "call-legacy"}

      assert {:ok, %{status: :accepted, decision: v1}} =
               project_attention(pid, minimal_attention(), source: legacy_source)

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{status: :duplicate, decision: ^v1}} =
               project_attention(pid, minimal_attention(), source: legacy_source)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "equivalent enrichment content from a distinct action remains a duplicate", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{status: :accepted, decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-distinct"})

      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "an explicit stale version is rejected even when enrichment content is unchanged", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured = Map.put(minimal_attention(), "kind", "architecture")

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      stale = Map.put(structured, "version", 1)

      assert {:error, {:conflict, {:stale_version, 1, 2}}} =
               enrich_attention(pid, stale, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-distinct"})

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "a changed minimal question preserves structured enrichment fields", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention())

      structured =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("options", [%{"id" => "runtime", "label" => "Runtime"}])

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert {:ok, %{status: :accepted, decision: v3}} =
               project_attention(pid, minimal_attention("Which owner should take this now?"))

      assert v3.decision_id == v1.decision_id
      assert v3.version == 3
      assert v3.question == "Which owner should take this now?"
      assert v3.kind == v2.kind
      assert v3.options == v2.options
    end

    test "changed legacy evidence re-arms an operator-dismissed attention", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Original blocker evidence"))
      assert {:ok, %{decision: dismissed}} = DecisionStore.dismiss(v1.decision_id, [actor: %{kind: :operator, id: "dashboard"}], pid)
      assert dismissed.decision_status == :dismissed

      assert {:ok, %{decision: rearmed}} = project_attention(pid, minimal_attention("New blocker evidence"))
      assert rearmed.version == 2
      assert rearmed.decision_status == :open
    end

    test "a stale startup import cannot replace an enriched current question", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Original alert question?"))

      structured =
        minimal_attention("Current structured question?")
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "The request was clarified."})

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{status: :duplicate, decision: ^v2}} =
               project_attention(pid, minimal_attention("Original alert question?"), legacy_import: true)

      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "changing legacy questions cannot grow one Decision beyond its configured bound", %{dir: dir} do
      pid = start_store!(dir, legacy_question_version_limit: 3)

      assert {:ok, %{decision: v1}} = project_attention(pid, minimal_attention("Question one?"))
      assert {:ok, %{decision: v2}} = project_attention(pid, minimal_attention("Question two?"))
      assert {:ok, %{decision: v3}} = project_attention(pid, minimal_attention("Question three?"))

      assert {:error, {:legacy_attention, {:version_limit, 3}}} =
               project_attention(pid, minimal_attention("Question four?"))

      assert {:ok, ^v3} = DecisionStore.get(v1.decision_id, pid)
      assert {:ok, [^v1, ^v2, ^v3]} = DecisionStore.history(v1.decision_id, pid)
    end

    test "enrichment and later reminders preserve the original alert timestamp", %{dir: dir} do
      pid = start_store!(dir)

      minimal = Map.put(minimal_attention(), "created_at", "2026-07-12T01:00:00Z")
      assert {:ok, %{decision: v1}} = project_attention(pid, minimal)

      structured =
        minimal_attention()
        |> Map.put("kind", "architecture")
        |> Map.put("context", %{"short_summary" => "Structured context"})

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid, structured, source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-enrich"})

      assert {:ok, %{decision: v3}} =
               project_attention(pid, minimal_attention("Which owner now?"))

      assert v1.source_created_at == ~U[2026-07-12 01:00:00Z]
      assert v2.source_created_at == v1.source_created_at
      assert v3.source_created_at == v1.source_created_at
    end

    test "an enrichment without an existing legacy attention fails closed", %{dir: dir} do
      pid = start_store!(dir)

      assert {:error, {:legacy_attention, :not_found}} =
               enrich_attention(pid, minimal_attention(), source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      assert DecisionStore.list(pid) == []
    end

    test "legacy history and provenance survive restart", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: v1}} = project_attention(pid1, minimal_attention())

      assert {:ok, %{decision: v2}} =
               enrich_attention(pid1, Map.put(minimal_attention(), "kind", "architecture"), source: %{agent_id: "agent-1", session_id: "session-1", event_id: "call-2"})

      GenServer.stop(pid1)
      pid2 = start_store!(dir)

      assert DecisionStore.health(pid2) == :writable
      assert {:ok, ^v2} = DecisionStore.get(v1.decision_id, pid2)
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid2)
    end
  end

  describe "validation failures persist nothing" do
    test "an invalid payload is rejected without any append", %{dir: dir} do
      pid = start_store!(dir)
      assert {:error, {:decision_invalid, {:question, :missing}}} = request(pid, %{"blocking" => true})
      assert DecisionStore.list(pid) == []
    end
  end

  describe "restart recovery" do
    test "a fresh store instance replays durable state from the same path", %{dir: dir} do
      pid1 = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.question == accepted.question
      assert replayed.content_hash == accepted.content_hash
      assert DecisionStore.all_history(pid2)[accepted.decision_id] == [replayed]
      assert DecisionStore.health(pid2) == :writable
    end

    test "trusted provenance remains attached to its accepted version after replay", %{dir: dir} do
      pid1 = start_store!(dir)

      provenance = %{
        agent_family: "codex",
        backend: "codex",
        requested_model: "gpt-5.6-terra",
        session_id: "thread-123",
        attempt_id: "attempt-456",
        source: "agent_runner"
      }

      assert {:ok, %{decision: accepted}} =
               request(pid1, %{"question" => "Keep runtime facts?", "blocking" => true}, provenance: provenance)

      GenServer.stop(pid1)
      pid2 = start_store!(dir)

      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.provenance == accepted.provenance
      assert {:ok, [^replayed]} = DecisionStore.history(accepted.decision_id, pid2)

      assert [history] = DecisionHistory.list(server: pid2, limit: 1)
      assert history.provenance["backend"] == "codex"
      assert history.provenance["session_id"] == "thread-123"
    end

    test "replays trusted provenance and supervisor basis through the full revised lifecycle", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:provenance_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 711}}}
      end

      for confidence <- [0, 50, 100] do
        store_dir = Path.join(dir, "provenance-lifecycle-#{confidence}")
        pid = start_store!(store_dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

        provenance = %{
          agent_family: "codex",
          backend: "codex",
          requested_model: "gpt-5.6-terra",
          resolved_model: "gpt-5.6-terra",
          session_id: "thread-#{confidence}",
          attempt_id: "attempt-#{confidence}",
          source: "agent_runner"
        }

        assert {:ok, %{decision: accepted}} =
                 request(
                   pid,
                   %{
                     "question" => "Apply the approved architecture change?",
                     "blocking" => true,
                     "source_id" => "provenance-lifecycle-#{confidence}",
                     "kind" => "architecture",
                     "authority" => "supervisor_allowed",
                     "reversibility" => "reversible",
                     "options" => [%{"id" => "ship", "label" => "Ship it"}]
                   },
                   provenance: provenance
                 )

        supervisor_opts = [actor: %{kind: :supervisor, id: "supervising-agent"}, supervisor_basis: supervisor_basis(confidence)]

        assert {:ok, %{action: answer}} =
                 answer(
                   pid,
                   accepted.decision_id,
                   %{"idempotency_key" => "provenance-answer-#{confidence}", "expected_version" => 1, "option_id" => "ship"},
                   supervisor_opts
                 )

        assert_receive {:provenance_lifecycle_attempt, _initial_attempt_id}, 1_000
        _queued = wait_for_decision(pid, accepted.decision_id, &(&1.delivery_status == :queued))

        assert {:ok, %{action: revision}} =
                 DecisionStore.revise(
                   accepted.decision_id,
                   %{
                     "idempotency_key" => "provenance-revision-#{confidence}",
                     "expected_version" => 1,
                     "expected_action_id" => answer.action_id,
                     "expected_revision_sequence" => 0,
                     "option_id" => "ship",
                     "rationale" => "Confirmed after the delivery check."
                   },
                   supervisor_opts,
                   pid
                 )

        assert_receive {:provenance_lifecycle_attempt, revision_attempt_id}, 1_000

        _queued =
          wait_for_decision(pid, accepted.decision_id, fn decision ->
            decision.delivery_status == :queued and decision.active_action_id == revision.action_id
          end)

        assert {:ok, :accepted} =
                 DecisionStore.record_delivery(correlated_queue_item(accepted, revision, revision_attempt_id, 711), pid)

        lifecycle_payload = %{
          "decision_id" => accepted.decision_id,
          "action_id" => revision.action_id,
          "expected_version" => 1
        }

        lifecycle_opts = [
          ticket_identifier: "979",
          actor: %{kind: :agent, id: "ticket-agent"},
          source: %{agent_id: "codex", session_id: "session-#{confidence}", invocation_id: "lifecycle-#{confidence}"}
        ]

        assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
                 DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

        assert {:ok, %{status: :accepted, decision_status: :resolved}} =
                 DecisionStore.agent_lifecycle(:resolved, lifecycle_payload, lifecycle_opts, pid)

        GenServer.stop(pid)
        replayed_pid = start_store!(store_dir, dispatch_delay_ms: 60_000)

        assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, replayed_pid)
        assert replayed.provenance == accepted.provenance
        assert replayed.answer.supervisor_basis.confidence == confidence
        assert List.last(replayed.revisions).answer.supervisor_basis.confidence == confidence
        assert replayed.delivery_status == :delivered
        assert replayed.decision_status == :resolved
        assert replayed.acknowledgement.action_id == revision.action_id
        assert replayed.resolution.action_id == revision.action_id

        history = DecisionHistory.list(server: replayed_pid)

        assert Enum.all?(history, &(&1.provenance["backend"] == "codex"))

        assert Enum.any?(history, fn entry ->
                 entry.change == :answered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.change == :revised and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.dispatch_result == :delivered and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :acknowledged and entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(history, fn entry ->
                 entry.acknowledgement_result == :resolved and entry.supervisor_basis["confidence"] == confidence
               end)

        limited_history = DecisionHistory.list(server: replayed_pid, limit: 50)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == answer.action_id and entry.dispatch_result == :dispatch_queued and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        assert Enum.any?(limited_history, fn entry ->
                 entry.action_id == revision.action_id and entry.dispatch_result == :delivered and
                   entry.supervisor_basis["confidence"] == confidence
               end)

        GenServer.stop(replayed_pid)
      end
    end

    test "a decision with an artifact survives restart without being flagged as corrupt", %{dir: dir} do
      pid1 = start_store!(dir)

      payload = %{
        "question" => "Deploy now?",
        "blocking" => true,
        "source_id" => "retry-1",
        "artifacts" => ["https://github.com/its-everdred/aiur"]
      }

      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      assert [%{kind: :url}] = accepted.artifacts
      GenServer.stop(pid1)

      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(accepted.decision_id, pid2)
      assert replayed.artifacts == accepted.artifacts
    end
  end

  test "accepts and replays an executor-attributed answer without supervisor policy evidence", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Reuse the established answer?",
               "blocking" => true,
               "authority" => "supervisor_allowed",
               "reversibility" => "reversible",
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-answer",
                 "expected_version" => 1,
                 "option_id" => "yes"
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
    assert answer.supervisor_basis == nil

    assert {:ok, [_requested, %DecisionEvent{type: :answer_recorded, data: ^answer}]} =
             DecisionStore.audit_history(decision.decision_id, pid)

    GenServer.stop(pid)
    replayed = start_store!(dir, dispatch_delay_ms: 60_000)
    assert DecisionStore.health(replayed) == :writable
    assert {:ok, durable} = DecisionStore.get(decision.decision_id, replayed)
    assert durable.answer == answer
  end

  test "refuses an Executor answer for any Command the operator should see", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    delegable = %{
      "blocking" => true,
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "options" => [%{"id" => "yes", "label" => "Yes"}]
    }

    refused = [
      {"human_required authority", %{"authority" => "human_required"}, {:authority, :human_required}},
      {"an irreversible outcome", %{"reversibility" => "irreversible"}, {:reversibility, :irreversible}},
      {"a partially reversible outcome", %{"reversibility" => "partially_reversible"}, {:reversibility, :partially_reversible}}
    ]

    for {label, override, expected} <- refused do
      payload = delegable |> Map.merge(override) |> Map.put("question", "Escalate #{label}?")
      assert {:ok, %{decision: decision}} = request(pid, payload)

      assert {:error, {:answer_invalid, {:executor_scope, ^expected}}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{"idempotency_key" => "executor-#{label}", "expected_version" => 1, "option_id" => "yes"},
                 [actor: %{kind: :executor, id: "executor-1"}],
                 pid
               )

      # Refused, not recorded: the Command stays open for the operator.
      assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)

      # The operator keeps the authority the Executor was just denied.
      assert {:ok, %{status: :accepted}} =
               answer(pid, decision.decision_id, %{
                 "idempotency_key" => "operator-#{label}",
                 "expected_version" => 1,
                 "option_id" => "yes"
               })
    end
  end

  test "fails an Executor answer closed when the Command declares no delegable policy", %{dir: dir} do
    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    # No authority or reversibility supplied: the request defaults are
    # human_required/irreversible, so an absent declaration must refuse rather
    # than fall through to the permissive branch.
    assert {:ok, %{decision: decision}} = request(pid, %{"question" => "Undeclared policy?", "blocking" => true})
    assert decision.authority == :human_required
    assert decision.reversibility == :irreversible

    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "executor-undeclared",
                 "expected_version" => 1,
                 "custom_response" => "Looks obvious to me."
               },
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )
  end

  test "an Executor answer never opens an operator attention", %{dir: dir} do
    # `executor_attention_opener` is the store's only path to an operator
    # alert for a Command, so flunking it is the real form of "answering
    # directly does not page the operator".
    opener = fn _decision, _executor_id, _reason -> flunk("a direct Executor answer must not alert the operator") end
    pid = start_store!(dir, executor_attention_opener: opener, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Answer this without paging anyone?",
               "blocking" => true,
               "authority" => "supervisor_preferred",
               "reversibility" => "reversible",
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    assert {:ok, %{status: :accepted, action: answer}} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "executor-quiet", "expected_version" => 1, "option_id" => "yes"},
               [actor: %{kind: :executor, id: "executor-1"}],
               pid
             )

    assert answer.actor == %{kind: :executor, id: "executor-1"}
  end

  test "records an Executor escalation durably, attributably, and idempotently", %{dir: dir} do
    pid = start_store!(dir, executor_attention_opener: fn _d, _e, _r -> {:ok, :opened} end, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Rename the public API?", "blocking" => true})

    assert {:ok, %{status: :opened}} =
             DecisionStore.escalate_executor_command(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", reason: "This changes a published contract."},
               pid
             )

    assert {:ok, history} = DecisionStore.audit_history(decision.decision_id, pid)

    assert [%DecisionEvent{type: :executor_escalated, decision_version: 1, data: data}] =
             Enum.filter(history, &(&1.type == :executor_escalated))

    assert data.actor == %{kind: :executor, id: "executor-1"}
    assert data.detail == "This changes a published contract."

    # Deferring to the operator must not consume the Command.
    assert {:ok, %Decision{decision_status: :open, answer: nil}} = DecisionStore.get(decision.decision_id, pid)

    # A repeated escalation of the same version is a no-op append.
    assert {:ok, %{status: _status}} =
             DecisionStore.escalate_executor_command(
               decision.decision_id,
               %{expected_version: 1, executor_id: "executor-1", reason: "Same reason, retried."},
               pid
             )

    assert {:ok, replayed_history} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.count(replayed_history, &(&1.type == :executor_escalated)) == 1

    GenServer.stop(pid)
    restarted = start_store!(dir, dispatch_delay_ms: 60_000)
    assert DecisionStore.health(restarted) == :writable

    assert {:ok, durable} = DecisionStore.audit_history(decision.decision_id, restarted)

    assert [%DecisionEvent{type: :executor_escalated, data: durable_data}] =
             Enum.filter(durable, &(&1.type == :executor_escalated))

    assert durable_data == data
    assert {:ok, %Decision{decision_status: :open}} = DecisionStore.get(decision.decision_id, restarted)
  end

  test "answering an escalated Command clears its operator attention", %{dir: dir} do
    unless Process.whereis(IdGenerator) do
      start_supervised!({IdGenerator, name: IdGenerator, path: Path.join(dir, "executor-escalation-event-id.json"), batch_size: 50})
    end

    previous_log_file = Application.get_env(:aiur, :log_file)
    log_root = Path.join(dir, "executor-escalation-log")
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

    on_exit(fn ->
      if previous_log_file,
        do: Application.put_env(:aiur, :log_file, previous_log_file),
        else: Application.delete_env(:aiur, :log_file)
    end)

    pid = start_store!(dir, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{"question" => "Change the release scope?", "blocking" => true})

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert ExecutorCommandCLI.escalate(
                      [
                        decision_id: decision.decision_id,
                        expected_version: decision.version,
                        reason: "This changes product scope."
                      ],
                      decision_store: pid
                    ) == 0
           end) =~ "escalated Command"

    topic = ExecutorCommandAttention.topic(decision.decision_id, decision.ticket.identifier)
    alert_opts = [roots: [], log_roots: [log_root]]
    assert AlertFeed.active_ticket_attention?(topic, alert_opts)

    assert {:ok, %{status: :accepted}} =
             answer(pid, decision.decision_id, %{
               "idempotency_key" => "operator-answer-after-escalation",
               "expected_version" => decision.version,
               "custom_response" => "Keep the existing scope."
             })

    refute AlertFeed.active_ticket_attention?(topic, alert_opts)
  end

  test "serializes Executor escalation before a concurrent answer", %{dir: dir} do
    unless Process.whereis(IdGenerator) do
      start_supervised!({IdGenerator, name: IdGenerator, path: Path.join(dir, "executor-serialize-event-id.json"), batch_size: 50})
    end

    parent = self()

    opener = fn _decision, _executor_id, _reason ->
      send(parent, {:attention_opening, self()})

      receive do
        :finish_attention -> {:ok, :opened}
      end
    end

    pid = start_store!(dir, executor_attention_opener: opener, dispatch_delay_ms: 60_000)

    assert {:ok, %{decision: decision}} =
             request(pid, %{
               "question" => "Serialize this escalation?",
               "blocking" => true,
               "options" => [%{"id" => "yes", "label" => "Yes"}]
             })

    spawn(fn ->
      result =
        DecisionStore.escalate_executor_command(
          decision.decision_id,
          %{expected_version: 1, executor_id: "executor-1", reason: "Needs operator judgment"},
          pid
        )

      send(parent, {:escalation_result, result})
    end)

    # The escalation runs on a spawned process, so the attention-opener signal
    # is a genuine async event; the ExUnit default 100ms is far tighter than
    # this file's own convention for spawned-process waits (2s elsewhere) and
    # times out under CI load (#1920). Wait for the real signal, not a guess.
    assert_receive {:attention_opening, opener_pid}, 2_000

    spawn(fn ->
      result =
        answer(pid, decision.decision_id, %{
          "idempotency_key" => "answer-after-escalation",
          "expected_version" => 1,
          "option_id" => "yes"
        })

      send(parent, {:answer_result, result})
    end)

    refute_receive {:answer_result, _result}, 100
    send(opener_pid, :finish_attention)

    assert_receive {:escalation_result, {:ok, %{status: :opened}}}
    assert_receive {:answer_result, {:ok, %{status: :accepted}}}
  end

  describe "answer outbox" do
    test "persists the answer before dispatch and then records queue acceptance", %{dir: dir} do
      parent = self()

      dispatcher = fn decision, opts ->
        audit = DecisionStore.audit_history(decision.decision_id, opts[:store])
        send(parent, {:dispatch_observed, audit, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 41}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      assert {:ok, %{decision: decision}} =
               request(pid, %{
                 "question" => "Deploy now?",
                 "blocking" => true,
                 "source_id" => "answer-1",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               })

      :ok = Exchange.subscribe("ticket.979.agent.decision.answered")
      :ok = Exchange.subscribe("ticket.979.agent.decision.queued")
      :ok = DecisionPubSub.subscribe()

      payload = %{"idempotency_key" => "submit-1", "expected_version" => 1, "option_id" => "ship"}

      assert {:ok, %{status: :accepted, action: accepted, dispatch_status: :dispatch_pending}} =
               answer(pid, decision.decision_id, payload)

      assert_receive {:dispatch_observed, {:ok, audit}, attempt_id}, 1_000
      assert Enum.map(audit, &audit_type/1) == [:requested, :answer_recorded]
      assert String.starts_with?(attempt_id, accepted.action_id)

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.answer == accepted
      assert [%{queue_item_id: 41, attempt_id: ^attempt_id, status: :queued}] = settled.dispatch_attempts
      assert_receive {:event, %{topic: "ticket.979.agent.decision.answered"}}, 500
      assert_receive {:event, %{topic: "ticket.979.agent.decision.queued"}}, 500
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
      assert_receive {:decision_changed, ^decision_id, 1}, 500
    end

    test "exact answer replay is duplicate while changed content under the action conflicts", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, _opts ->
        send(parent, :dispatched)
        {:ok, %{status: :accepted, item: %{id: 42}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-dedup"))

      payload = %{
        "idempotency_key" => "submit-1",
        "expected_version" => 1,
        "custom_response" => "Proceed carefully",
        "rationale" => "Checks passed"
      }

      assert {:ok, %{status: :accepted, action: accepted}} = answer(pid, decision.decision_id, payload)
      assert_receive :dispatched, 1_000
      _settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert {:ok, %{status: :duplicate, action: ^accepted}} = answer(pid, decision.decision_id, payload)
      refute_receive :dispatched, 100

      changed = Map.put(payload, "rationale", "Different rationale")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed)

      assert action_id == accepted.action_id
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :answer_recorded)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :dispatch_queued)) == 1
    end

    test "dispatch timeout settles once and ignores a late correlated result", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Timeout")

      start_supervised!(
        {DecisionDispatchTasks, name: coordinator, operation_timeout_ms: 20},
        id: coordinator
      )

      dispatcher = fn _decision, opts ->
        send(parent, {:timeout_dispatch_started, self(), opts[:attempt_id]})
        receive do: (:never -> :ok)
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-timeout"))
      payload = %{"idempotency_key" => "timeout-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:timeout_dispatch_started, worker, attempt_id}, 1_000
      worker_ref = Process.monitor(worker)

      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_timeout"

      correlation = %{decision_id: decision.decision_id, action_id: action.action_id, attempt_id: attempt_id}
      send(pid, {:dispatch_result, correlation, {:ok, %{status: :accepted, item: %{id: 401}}}})
      _state = :sys.get_state(pid)

      assert {:ok, still_failed} = DecisionStore.get(decision.decision_id, pid)
      assert still_failed.delivery_status == :failed
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :failed)) == 1
      refute Enum.any?(audit, &(audit_type(&1) == :dispatch_queued))
    end

    test "an externally killed dispatch worker settles a specific durable failure", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("KilledWorker")
      start_supervised!({DecisionDispatchTasks, name: coordinator}, id: coordinator)

      dispatcher = fn _decision, _opts ->
        send(parent, {:kill_dispatch_worker, self()})
        receive do: (:never -> :ok)
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-killed-worker"))
      payload = %{"idempotency_key" => "killed-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:kill_dispatch_worker, worker}, 1_000
      Process.exit(worker, :kill)

      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_task_exit"
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :failed)) == 1
    end

    test "saturation fails admission durably and opens delivery attention", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Saturation")
      log_root = Path.join(dir, "dispatch-saturation-alert-log")
      original_log_file = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file,
          do: Application.put_env(:aiur, :log_file, original_log_file),
          else: Application.delete_env(:aiur, :log_file)
      end)

      start_supervised!(
        {DecisionDispatchTasks, name: coordinator, max_concurrency: 1, max_pending: 1, saturation_notifier: fn _ -> :ok end},
        id: coordinator
      )

      dispatcher = fn dispatched, opts ->
        send(parent, {:saturation_dispatch_started, dispatched.decision_id, self()})

        receive do
          :release -> {:ok, %{status: :accepted, item: %{id: 500 + String.length(opts[:attempt_id])}}}
        end
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      # Distinct questions so creation-time dedup (#2099) does not collapse the
      # three concurrently-open Commands this scenario needs for dispatch
      # admission; they represent three separate dispatch attempts.
      requests = [
        {"saturation-active", "Deploy the active change?"},
        {"saturation-queued", "Deploy the queued change?"},
        {"saturation-rejected", "Deploy the rejected change?"}
      ]

      decisions =
        for {source, question} <- requests do
          assert {:ok, %{decision: decision}} =
                   request(pid, %{answerable_request(source) | "question" => question})

          decision
        end

      [active, queued, rejected] = decisions

      for {decision, key} <- Enum.zip([active, queued], ["active-1", "queued-1"]) do
        payload = %{"idempotency_key" => key, "expected_version" => 1, "option_id" => "ship"}
        assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      end

      assert_receive {:saturation_dispatch_started, active_id, active_worker}, 1_000
      assert active_id == active.decision_id
      wait_for_dispatch_count(pid, 2)

      payload = %{"idempotency_key" => "rejected-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: rejected_action}} = answer(pid, rejected.decision_id, payload)

      failed = wait_for_decision(pid, rejected.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_overloaded"

      topic =
        "ticket.979.agent.attention.decision-delivery-#{String.replace(rejected_action.action_id, "_", "-")}"

      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)
      send(active_worker, :release)
      assert_receive {:saturation_dispatch_started, queued_id, queued_worker}, 1_000
      assert queued_id == queued.decision_id
      send(queued_worker, :release)
    end

    test "coordinator restart fails active and queued work and allows explicit retry", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Restart")

      coordinator_pid =
        start_supervised!(
          {DecisionDispatchTasks, name: coordinator, max_concurrency: 1},
          id: coordinator
        )

      dispatcher = fn dispatched, opts ->
        if String.ends_with?(opts[:attempt_id], ":1") do
          send(parent, {:restart_dispatch_started, dispatched.decision_id, self()})
          receive do: (:never -> :ok)
        else
          send(parent, {:restart_retry_started, dispatched.decision_id, opts[:attempt_id]})
          {:ok, %{status: :accepted, item: %{id: 601}}}
        end
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      decisions =
        for source <- ["restart-active", "restart-queued"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
          {decision, action}
        end

      [{active, _active_action}, {queued, queued_action}] = decisions
      assert_receive {:restart_dispatch_started, active_id, orphaned_worker}, 1_000
      assert active_id == active.decision_id
      wait_for_dispatch_count(pid, 2)
      orphaned_worker_ref = Process.monitor(orphaned_worker)

      Process.exit(coordinator_pid, :kill)
      assert_receive {:DOWN, ^orphaned_worker_ref, :process, ^orphaned_worker, :killed}, 1_000

      for {decision, _action} <- decisions do
        failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
        assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_coordinator_exit"
      end

      restarted = wait_for_named_process(coordinator, coordinator_pid)
      assert Process.alive?(restarted)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(queued.decision_id, queued_action.action_id, pid)
      assert_receive {:restart_retry_started, queued_id, retry_attempt_id}, 1_000
      assert queued_id == queued.decision_id
      assert String.ends_with?(retry_attempt_id, ":2")

      settled = wait_for_decision(pid, queued.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
    end

    test "store restart purges old-owner dispatches before boot reconciliation", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("StoreRestart")
      start_supervised!({DecisionDispatchTasks, name: coordinator, max_concurrency: 1}, id: coordinator)
      {:ok, mode} = Agent.start_link(fn -> :hang end)

      dispatcher = fn dispatched, _opts ->
        case Agent.get(mode, & &1) do
          :hang ->
            send(parent, {:old_store_dispatch_started, dispatched.decision_id, self()})
            receive do: (:never -> :ok)

          :recover ->
            send(parent, {:reconciled_dispatch_started, dispatched.decision_id})
            {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
        end
      end

      pid1 =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0
        )

      decisions =
        for source <- ["store-restart-active", "store-restart-queued"] do
          assert {:ok, %{decision: decision}} = request(pid1, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, _result} = answer(pid1, decision.decision_id, payload)
          decision
        end

      assert_receive {:old_store_dispatch_started, _decision_id, old_worker}, 2_000
      wait_for_dispatch_count(pid1, 2)
      old_worker_ref = Process.monitor(old_worker)
      Agent.update(mode, fn _ -> :recover end)
      GenServer.stop(pid1)
      assert_receive {:DOWN, ^old_worker_ref, :process, ^old_worker, _reason}, 2_000

      pid2 =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0
        )

      for decision <- decisions do
        assert_receive {:reconciled_dispatch_started, decision_id}, 2_000
        assert decision_id in Enum.map(decisions, & &1.decision_id)

        queued = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
        assert Enum.map(queued.dispatch_attempts, & &1.status) == [:queued]
      end
    end

    test "concurrent distinct answers serialize to one winner", %{dir: dir} do
      dispatcher = fn _decision, _opts -> {:error, :no_running_agent} end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 20)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-race"))

      submissions = [
        %{"idempotency_key" => "race-1", "expected_version" => 1, "custom_response" => "First"},
        %{"idempotency_key" => "race-2", "expected_version" => 1, "custom_response" => "Second"}
      ]

      results =
        submissions
        |> Enum.map(&Task.async(fn -> answer(pid, decision.decision_id, &1) end))
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, %{status: :accepted}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:conflict, {:already_decided, _}}}, &1)) == 1
    end

    test "a stale request version rejects before append or dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher)
      base = answerable_request("answer-stale")

      assert {:ok, %{decision: v1}} = request(pid, base)
      assert {:ok, %{decision: v2}} = request(pid, Map.merge(base, %{"question" => "Revised?", "version" => 2}))

      stale = %{"idempotency_key" => "stale-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:error, {:conflict, {:stale_version, 1, 2}}} = answer(pid, v1.decision_id, stale)
      refute_receive :unexpected_dispatch, 100
      assert v2.answer == nil
      assert {:ok, audit} = DecisionStore.audit_history(v1.decision_id, pid)
      assert Enum.map(audit, &audit_type/1) == [:requested, :requested]
    end

    test "request enrichment after answer keeps dispatch tied to the answered version", %{dir: dir} do
      parent = self()

      dispatcher = fn addressed, _opts ->
        send(parent, {:addressed_request, addressed.version, addressed.question})
        {:ok, %{status: :accepted, item: %{id: 55}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 100)
      base = answerable_request("answer-enrichment")
      assert {:ok, %{decision: v1}} = request(pid, base)

      payload = %{"idempotency_key" => "enrich-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, v1.decision_id, payload)

      assert {:ok, %{decision: v2}} =
               request(pid, Map.merge(base, %{"question" => "Revised after answer?", "version" => 2}))

      assert v2.version == 2
      assert v2.answer == action
      assert_receive {:addressed_request, 1, "Deploy now?"}, 1_000

      settled = wait_for_decision(pid, v1.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert settled.answer.decision_version == 1
    end

    test "restart reconciles a persisted answer that was not yet dispatched", %{dir: dir} do
      parent = self()
      never = fn _decision, _opts -> send(parent, :old_dispatch) end
      pid1 = start_store!(dir, dispatcher: never, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid1, answerable_request("answer-restart"))

      payload = %{"idempotency_key" => "restart-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted, action: action}} = answer(pid1, decision.decision_id, payload)
      GenServer.stop(pid1)
      refute_receive :old_dispatch, 100

      dispatcher = fn replayed, opts ->
        send(parent, {:reconciled, replayed.answer.action_id, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 77}}}
      end

      pid2 = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, reconcile_delay_ms: 0)
      assert_receive {:reconciled, action_id, _attempt_id}, 1_000
      assert action_id == action.action_id
      _settled = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
      refute_receive {:reconciled, _, _}, 100
    end

    test "transient dispatch failure is retried after request enrichment", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:attempted, attempt, opts[:attempt_id]})

        if attempt == 1,
          do: {:error, :unavailable},
          else: {:ok, %{status: :accepted, item: %{id: 88}}}
      end

      dispatch_scheduler = fn recipient, message, delay_ms ->
        send(parent, {:retry_scheduled, recipient, message, delay_ms})
        make_ref()
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          reconcile_delay_ms: 0,
          retry_delays_ms: [0],
          dispatch_scheduler: dispatch_scheduler
        )

      assert_receive {:retry_scheduled, ^pid, {:reconcile_dispatches, []}, 0}, 2_000
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-enrichment"))
      payload = %{"idempotency_key" => "retry-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)

      assert_receive {:retry_scheduled, ^pid, first_dispatch, 0}, 2_000
      send(pid, first_dispatch)
      assert_receive {:attempted, 1, first_attempt}, 1_000
      assert_receive {:retry_scheduled, ^pid, scheduled_retry, 0}, 2_000

      patch = %{"context" => %{"short_summary" => "Context before retry"}}

      assert {:ok, %{status: :accepted, decision: enriched}} =
               enrich(pid, decision.decision_id, patch, 1)

      assert enriched.version == 2
      assert enriched.delivery_status == :failed
      assert Enum.map(enriched.dispatch_attempts, & &1.status) == [:failed]

      send(pid, scheduled_retry)
      assert_receive {:attempted, 2, second_attempt}, 1_000
      refute first_attempt == second_attempt

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert settled.version == 2
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert hd(settled.dispatch_attempts).failure_reason_class == "orchestrator_unavailable"
    end

    test "target-agent failure waits for an explicit idempotent retry", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "target-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, opts ->
        :ok = :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        send(parent, {:target_attempt, attempt, opts[:retry_failed]})

        if attempt == 1,
          do: {:error, :no_running_agent},
          else: {:ok, %{status: :accepted, item: %{id: 89}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [0])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-explicit-retry"))
      payload = %{"idempotency_key" => "retry-2", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)

      assert_receive {:target_attempt, 1, false}, 1_000
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "target_agent_unavailable"

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      refute_receive {:target_attempt, _, _}, 100

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:target_attempt, 2, true}, 1_000
      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "projection repair failure after answer append suppresses dispatch", %{dir: dir} do
      parent = self()
      dispatcher = fn _decision, _opts -> send(parent, :unexpected_dispatch) end
      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-repair"))

      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      payload = %{"idempotency_key" => "repair-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, %{status: :accepted}} = answer(pid, decision.decision_id, payload)
      assert {:repair, _reason} = DecisionStore.health(pid)
      refute_receive :unexpected_dispatch, 100
    end

    test "background lifecycle append failure stays scoped and can be retried", %{dir: dir} do
      parent = self()
      reservation_count = :counters.new(1, [])
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "append-failure-alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      event_id_reserver = fn ->
        :ok = :counters.add(reservation_count, 1, 1)
        reservation = :counters.get(reservation_count, 1)
        send(parent, {:lifecycle_reservation, reservation})

        if reservation == 2,
          do: {:error, :not_durable},
          else: IdGenerator.reserve_durable_id()
      end

      dispatcher = fn _decision, _opts ->
        send(parent, :background_dispatch)
        {:ok, %{status: :accepted, item: %{id: 96}}}
      end

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          retry_delays_ms: [],
          event_id_reserver: event_id_reserver
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-append-failure"))
      payload = %{"idempotency_key" => "append-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:lifecycle_reservation, 1}, 1_000
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 2}, 1_000

      assert DecisionStore.health(pid) == :writable
      assert {:ok, %{status: :accepted}} = request(pid, %{"question" => "Independent?", "blocking" => false})

      topic =
        "ticket.979.agent.attention.decision-lifecycle-persistence-#{String.replace(action.action_id, "_", "-")}"

      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive :background_dispatch, 1_000
      assert_receive {:lifecycle_reservation, 3}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "boot reconciliation tolerates failed delivery without an attempt", %{dir: dir} do
      pid = start_store!(dir, dispatch_delay_ms: 5_000, reconcile_delay_ms: 5_000)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-empty-failure"))
      payload = %{"idempotency_key" => "empty-failure-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)

      malformed = %{current | delivery_status: :failed, dispatch_attempts: []}
      state = :sys.get_state(pid)
      state = %{state | current: Map.put(state.current, decision.decision_id, malformed)}

      assert {:noreply, _state} = DecisionStore.handle_continue(:schedule_reconciliation, state)
    end

    test "correlated handoff and consumption append idempotent transport evidence", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 91}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-transport"))
      payload = %{"idempotency_key" => "transport-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 91)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, :duplicate} = DecisionStore.record_delivery(item, pid)

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
      assert consumed.decision_status == :decided

      assert :ok = DecisionStore.record_transport_async(:consumed, item, nil, pid)
      Process.sleep(20)
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :delivered)) == 1
      assert Enum.count(audit, &(audit_type(&1) == :consumed)) == 1
    end

    test "delivery adopts queue acceptance when handoff wins the settlement race", %{dir: dir} do
      parent = self()

      dispatcher = fn dispatched, opts ->
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 97)
        send(parent, {:handoff_before_settlement, self(), item})

        receive do
          :release_settlement -> {:ok, %{status: :accepted, item: item}}
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-handoff-race"))
      payload = %{"idempotency_key" => "handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)
      assert_receive {:handoff_before_settlement, dispatcher_pid, item}, 1_000

      assert {:ok, :accepted} = DecisionStore.validate_delivery(item, pid)
      assert {:ok, before_delivery} = DecisionStore.get(decision.decision_id, pid)
      assert before_delivery.dispatch_attempts == []

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{attempt_id: attempt_id, status: :delivered}] = delivered.dispatch_attempts
      assert attempt_id == item.correlation.attempt_id

      send(dispatcher_pid, :release_settlement)
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "delivery adopts restoration when a failed retry wins the settlement race", %{dir: dir} do
      parent = self()
      dispatches = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(dispatches, 1, 1)

        case :counters.get(dispatches, 1) do
          1 ->
            item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], 98)
            send(parent, {:initial_retry_item, item})
            {:ok, %{status: :accepted, item: item}}

          2 ->
            send(parent, {:retry_before_settlement, self()})

            receive do
              {:release_retry_settlement, item} -> {:ok, %{status: :retried, item: item}}
            end
        end
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0, retry_delays_ms: [])
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry-handoff-race"))
      payload = %{"idempotency_key" => "retry-handoff-race-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:initial_retry_item, item}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      _failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:retry_before_settlement, dispatcher_pid}, 1_000

      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      delivered = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :delivered))
      assert [%{status: :delivered}] = delivered.dispatch_attempts

      send(dispatcher_pid, {:release_retry_settlement, Map.put(item, :status, :pending)})
      Process.sleep(50)
      assert {:ok, settled} = DecisionStore.get(decision.decision_id, pid)
      assert [%{status: :delivered}] = settled.dispatch_attempts
    end

    test "batched queue settlement records every item through one store message", %{dir: dir} do
      parent = self()
      ids = :counters.new(1, [])

      dispatcher = fn dispatched, opts ->
        :ok = :counters.add(ids, 1, 1)
        item_id = 100 + :counters.get(ids, 1)
        item = correlated_queue_item(dispatched, dispatched.answer, opts[:attempt_id], item_id)
        send(parent, {:batch_queue_item, dispatched.decision_id, item})
        {:ok, %{status: :accepted, item: item}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)

      decisions =
        for source <- ["batch-one", "batch-two"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, _result} = answer(pid, decision.decision_id, payload)
          decision
        end

      items_by_decision =
        for _index <- 1..2, into: %{} do
          assert_receive {:batch_queue_item, decision_id, item}, 1_000
          {decision_id, item}
        end

      items =
        for decision <- decisions do
          item = Map.fetch!(items_by_decision, decision.decision_id)
          _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
          assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
          item
        end

      assert :ok = DecisionStore.record_transport_batch_async(:consumed, items, nil, pid)

      for decision <- decisions do
        consumed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :consumed))
        assert [%{status: :consumed}] = consumed.dispatch_attempts
      end
    end

    test "durable transport failure opens one stable attention and restoration resolves it", %{dir: dir} do
      parent = self()
      original_log_file = Application.get_env(:aiur, :log_file)
      log_root = Path.join(dir, "alert-log")
      Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))

      on_exit(fn ->
        if original_log_file do
          Application.put_env(:aiur, :log_file, original_log_file)
        else
          Application.delete_env(:aiur, :log_file)
        end
      end)

      dispatcher = fn _decision, opts ->
        send(parent, {:queue_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 92}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-attention"))
      payload = %{"idempotency_key" => "attention-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
      assert_receive {:queue_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      item = correlated_queue_item(decision, action, attempt_id, 92)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      topic = "ticket.979.agent.attention.decision-delivery-#{String.replace(action.action_id, "_", "-")}"

      assert :ok = DecisionStore.record_transport_async(:failed, item, :send_failed, pid)
      failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
      assert List.last(failed.dispatch_attempts).failure_reason_class == "send_failed"
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      GenServer.stop(pid)
      pid2 = start_store!(dir, dispatcher: fn _decision, _opts -> {:error, :no_running_agent} end)
      assert [%{"topic" => ^topic}] = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

      assert :ok = DecisionStore.record_transport_async(:restored, item, nil, pid2)
      _restored = wait_for_decision(pid2, decision.decision_id, &(&1.delivery_status == :queued))
      assert AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) == []
    end

    test "target agent explicitly acknowledges and resolves with duplicate suppression", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 93}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle"))
      answer_payload = %{"idempotency_key" => "lifecycle-1", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      item = correlated_queue_item(decision, action, attempt_id, 93)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)

      assert {:ok, %{decision: advanced}} =
               request(
                 pid,
                 answerable_request("answer-lifecycle")
                 |> Map.merge(%{"question" => "Deploy now with the latest context?", "version" => 2})
               )

      assert advanced.version == 2
      assert Aiur.Decision.active_answer(advanced).action_id == action.action_id

      :ok = Exchange.subscribe("ticket.979.agent.decision.acknowledged")
      :ok = Exchange.subscribe("ticket.979.agent.decision.resolved")

      lifecycle_payload = %{
        "decision_id" => decision.decision_id,
        "action_id" => action.action_id,
        "expected_version" => 1,
        "detail" => "Observed and applying the answer"
      }

      lifecycle_opts = [
        ticket_identifier: "979",
        actor: %{kind: :agent, id: "ticket-agent"},
        source: %{agent_id: "codex", session_id: "session-1", invocation_id: "call-1"}
      ]

      assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      assert_receive {:event, %{topic: "ticket.979.agent.decision.acknowledged", digest_source: :orchestrator} = acknowledged}, 500
      assert EventsDigest.render([acknowledged], "979") =~ "ticket.979.agent.decision.acknowledged"

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, pid)

      refute_receive {:event, %{topic: "ticket.979.agent.decision.acknowledged"}}, 100

      reconnected_opts =
        Keyword.put(lifecycle_opts, :source, %{
          agent_id: "codex",
          session_id: "session-2",
          invocation_id: "call-2"
        })

      assert {:ok, %{status: :duplicate}} =
               DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, reconnected_opts, pid)

      conflicting = Map.put(lifecycle_payload, "detail", "Different acknowledgement")

      assert {:error, {:conflict, {:already_acknowledged, action_id}}} =
               DecisionStore.agent_lifecycle(:acknowledged, conflicting, lifecycle_opts, pid)

      assert action_id == action.action_id

      resolved_payload = Map.put(lifecycle_payload, "detail", "Applied successfully")

      assert {:ok, %{status: :accepted, decision_status: :resolved}} =
               DecisionStore.agent_lifecycle(:resolved, resolved_payload, lifecycle_opts, pid)

      assert_receive {:event, %{topic: "ticket.979.agent.decision.resolved"}}, 500
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.acknowledgement.detail == "Observed and applying the answer"
      assert current.acknowledgement.source.session_id == "session-1"
      assert current.resolution.detail == "Applied successfully"

      assert {:ok, %{status: :duplicate, action: ^action}} =
               answer(pid, decision.decision_id, answer_payload)

      changed_answer = Map.put(answer_payload, "option_id", nil) |> Map.put("custom_response", "Different")

      assert {:error, {:conflict, {:idempotency_conflict, action_id}}} =
               answer(pid, decision.decision_id, changed_answer)

      assert action_id == action.action_id
    end

    test "agent lifecycle rejects wrong correlation and illegal ordering without append", %{dir: dir} do
      parent = self()

      dispatcher = fn _decision, opts ->
        send(parent, {:invalid_lifecycle_attempt, opts[:attempt_id]})
        {:ok, %{status: :accepted, item: %{id: 94}}}
      end

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-lifecycle-invalid"))
      answer_payload = %{"idempotency_key" => "lifecycle-2", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, %{action: action}} = answer(pid, decision.decision_id, answer_payload)
      assert_receive {:invalid_lifecycle_attempt, attempt_id}, 1_000
      _queued = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))

      payload = %{"decision_id" => decision.decision_id, "action_id" => action.action_id, "expected_version" => 1}
      opts = [ticket_identifier: "979", actor: %{kind: :agent, id: "agent-session-2"}]

      assert {:error, {:invalid_transition, :not_delivered}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:error, {:invalid_transition, :not_acknowledged}} =
               DecisionStore.agent_lifecycle(:resolved, payload, opts, pid)

      assert {:error, {:conflict, {:ticket_mismatch, "980", "979"}}} =
               DecisionStore.agent_lifecycle(:acknowledged, payload, Keyword.put(opts, :ticket_identifier, "980"), pid)

      wrong_action = Map.put(payload, "action_id", "act_wrong")

      assert {:error, {:conflict, {:action_mismatch, "act_wrong", _current}}} =
               DecisionStore.agent_lifecycle(:acknowledged, wrong_action, opts, pid)

      stale = Map.put(payload, "expected_version", 2)

      assert {:error, {:conflict, {:stale_version, 2, 1}}} =
               DecisionStore.agent_lifecycle(:acknowledged, stale, opts, pid)

      item = correlated_queue_item(decision, action, attempt_id, 94)
      assert {:ok, :accepted} = DecisionStore.record_delivery(item, pid)
      assert {:ok, %{status: :accepted}} = DecisionStore.agent_lifecycle(:acknowledged, payload, opts, pid)

      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(audit_type(&1) == :acknowledged)) == 1
      refute Enum.any?(audit, &(audit_type(&1) == :resolved))
    end
  end

  describe "corruption" do
    test "an interior-corrupt audit log boots read-only and keeps validated-prefix reads", %{dir: dir} do
      pid1 = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: accepted}} = request(pid1, payload)
      GenServer.stop(pid1)

      ndjson_path = Path.join(dir, "decisions.ndjson")
      File.write!(ndjson_path, "not json at all\n", [:append])

      pid2 = start_store!(dir)
      assert {:corrupt, 2, _reason} = DecisionStore.health(pid2)
      assert {:ok, ^accepted} = DecisionStore.get(accepted.decision_id, pid2)
      assert {:error, {:store_unavailable, {:corrupt, 2, _reason}}} = request(pid2, payload)
    end

    test "an unrecognised but well-formed event type replays writable and is not lost", %{dir: dir} do
      pid1 = start_store!(dir, dispatch_delay_ms: 60_000)

      assert {:ok, %{decision: decision}} =
               request(pid1, %{
                 "question" => "Survive a rollback?",
                 "blocking" => true,
                 "options" => [%{"id" => "yes", "label" => "Yes"}]
               })

      GenServer.stop(pid1)

      # Exactly the shape a newer binary writes: a complete envelope whose
      # event_type this build has never heard of.
      path = Path.join(dir, "decisions.ndjson")

      future_event = %{
        "schema_version" => 1,
        "event_type" => "some_future_event",
        "event_id" => "evt-from-a-newer-build",
        "run_id" => "run-newer-build",
        "decision_id" => decision.decision_id,
        "decision_version" => decision.version,
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "data" => %{"whatever" => "a shape this build cannot interpret"},
        "content_hash" => "hash-this-build-cannot-recompute"
      }

      :ok = DecisionLog.append(path, future_event)

      pid2 = start_store!(dir, dispatch_delay_ms: 60_000)

      # Version skew is not corruption: the store stays writable, so the
      # operator can still answer Commands.
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, replayed} = DecisionStore.get(decision.decision_id, pid2)
      assert replayed.decision_status == :open

      assert {:ok, %{status: :accepted}} =
               answer(pid2, decision.decision_id, %{
                 "idempotency_key" => "operator-after-skew",
                 "expected_version" => decision.version,
                 "option_id" => "yes"
               })

      assert {:ok, %{status: :accepted}} =
               request(pid2, %{"question" => "Still accepting new Commands?", "blocking" => false})

      # The unrecognised record is skipped for projection but never dropped, so
      # rolling forward again still sees it.
      assert path |> File.read!() |> String.contains?("some_future_event")

      GenServer.stop(pid2)
      pid3 = start_store!(dir, dispatch_delay_ms: 60_000)
      assert DecisionStore.health(pid3) == :writable

      assert {:ok, records, nil} = DecisionLog.replay(path, &DecisionProjection.decode_record/1)

      assert [%Unrecognized{event_type: "some_future_event", event_id: "evt-from-a-newer-build"} = retained] =
               Enum.filter(records, &match?(%Unrecognized{}, &1))

      assert retained.decision_id == decision.decision_id
      assert retained.raw["data"] == %{"whatever" => "a shape this build cannot interpret"}
    end

    test "a malformed record stays fail-closed even when its event type is unrecognised", %{dir: dir} do
      # Same unknown type, but the envelope this build *can* check is broken.
      # Forward compatibility must not become a hole that swallows damage.
      broken = [
        {"a missing decision_id", %{"decision_id" => nil}},
        {"a non-positive decision_version", %{"decision_version" => 0}},
        {"an unparseable occurred_at", %{"occurred_at" => "not-a-timestamp"}},
        {"a missing event_id", %{"event_id" => nil}},
        {"a non-map data payload", %{"data" => "not a map"}},
        {"a missing content_hash", %{"content_hash" => ""}},
        {"a missing run_id", %{"run_id" => nil}}
      ]

      for {label, override} <- broken do
        case_dir = Path.join(dir, "broken-#{System.unique_integer([:positive])}")
        pid1 = start_store!(case_dir)
        assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Reject #{label}?", "blocking" => true})
        GenServer.stop(pid1)

        record =
          Map.merge(
            %{
              "schema_version" => 1,
              "event_type" => "some_future_event",
              "event_id" => "evt-broken",
              "run_id" => "run-broken",
              "decision_id" => decision.decision_id,
              "decision_version" => decision.version,
              "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "data" => %{},
              "content_hash" => "hash"
            },
            override
          )

        :ok = DecisionLog.append(Path.join(case_dir, "decisions.ndjson"), record)

        pid2 = start_store!(case_dir)
        assert {:corrupt, 2, _reason} = DecisionStore.health(pid2), "#{label} must stay fail-closed"
        GenServer.stop(pid2)
      end
    end

    test "a valid envelope with an illegal lifecycle transition makes replay read-only", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Deploy now?", "blocking" => true})
      GenServer.stop(pid1)

      {:ok, invalid} =
        DecisionEvent.new(
          :delivered,
          decision.decision_id,
          decision.version,
          %{action_id: "act_missing", attempt_id: "attempt-1", queue_item_id: 7},
          event_id: "evt-illegal-transition",
          run_id: "run-replay-test"
        )

      :ok = DecisionLog.append(Path.join(dir, "decisions.ndjson"), DecisionEvent.to_json_safe(invalid))
      File.write!(Path.join(dir, "decisions.ndjson"), "not json at all\n", [:append])

      pid2 = start_store!(dir)
      assert {:corrupt, 2, {:invalid_transition, :answer_missing}} = DecisionStore.health(pid2)
      assert {:ok, replayed} = DecisionStore.get(decision.decision_id, pid2)
      assert replayed.decision_status == :open
    end

    test "an incomplete final lifecycle envelope is truncated and leaves the durable prefix writable", %{dir: dir} do
      pid1 = start_store!(dir)
      assert {:ok, %{decision: decision}} = request(pid1, %{"question" => "Deploy now?", "blocking" => true})
      GenServer.stop(pid1)

      path = Path.join(dir, "decisions.ndjson")
      File.write!(path, ~s({"event_type":"answer_recorded","decision_id":"#{decision.decision_id}"), [:append])

      pid2 = start_store!(dir)
      assert DecisionStore.health(pid2) == :writable
      assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid2)
      assert length(String.split(File.read!(path), "\n", trim: true)) == 1
    end
  end

  describe "repair mode" do
    test "a projection write failure during an accept logs and alerts, not just flips health silently", %{dir: dir} do
      pid = start_store!(dir)
      assert {:ok, %{status: :accepted}} = request(pid, %{"question" => "Q1?", "blocking" => true})

      # Make the projection's directory unwritable so its NEXT atomic write
      # (temp-file create + rename) fails, without touching the audit log.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :accepted}} =
                   request(pid, %{"question" => "Q2?", "blocking" => true, "source_id" => "other"})
        end)

      assert log =~ "aiur_decision_store phase=projection_repair_failed"
      assert {:repair, _reason} = DecisionStore.health(pid)
    end
  end

  describe "notification" do
    test "an accepted request fans out through Exchange under its reserved event id and broadcasts on PubSub",
         %{dir: dir} do
      pid = start_store!(dir)
      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      :ok = Exchange.subscribe("executor.decision.requested")
      :ok = DecisionPubSub.subscribe()

      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload)

      assert_receive {:event,
                      %{
                        "question" => "Deploy now?",
                        topic: "ticket.979.agent.decision.requested",
                        digest_source: :orchestrator,
                        id: cursor_event_id
                      } = request_event},
                     500

      assert cursor_event_id > 0
      assert EventsDigest.render([request_event], "979") =~ "ticket.979.agent.decision.requested"

      assert_receive {:event,
                      %{
                        topic: "executor.decision.requested",
                        decision_id: decision_id,
                        decision_version: 1,
                        issue_identifier: "979",
                        provenance: :decision_store
                      }},
                     500

      assert decision_id == decision.decision_id

      [persisted] =
        dir
        |> Path.join("decisions.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert persisted["event_id"] == "decision-provenance-v1:" <> Integer.to_string(cursor_event_id)
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
    end

    test "a duplicate does not fan out again", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, payload)

      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      :ok = Exchange.subscribe("executor.decision.requested")
      assert {:ok, %{status: :duplicate}} = request(pid, payload)
      refute_receive {:event, %{topic: "ticket.979.agent.decision.requested"}}, 200
      refute_receive {:event, %{topic: "executor.decision.requested"}}, 200
    end

    test "retries a failed requested notification from the canonical Decision", %{dir: dir} do
      unless Process.whereis(IdGenerator) do
        start_supervised!({IdGenerator, name: IdGenerator, path: Path.join(dir, "executor-request-retry-event-id.json"), batch_size: 50})
      end

      parent = self()

      publisher = fn decision ->
        send(parent, {:publish_failed, decision.decision_id, decision.version})
        {:error, :journal_unavailable}
      end

      reconciler = fn decision ->
        send(parent, {:reconciled, decision.decision_id, decision.version})
        {:ok, 1788, 1}
      end

      scheduler = fn server, message, _delay ->
        send(parent, {:retry_scheduled, server, message})
        make_ref()
      end

      pid =
        start_store!(dir,
          executor_request_publisher: publisher,
          executor_request_reconciler: reconciler,
          dispatch_scheduler: scheduler
        )

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Recover this Command?", "blocking" => true})

      assert_receive {:publish_failed, decision_id, 1}
      assert decision_id == decision.decision_id

      assert_receive {:retry_scheduled, ^pid, {:retry_executor_request_notification, ^decision_id, 1, 1} = retry_message}

      send(pid, retry_message)
      assert_receive {:reconciled, ^decision_id, 1}
    end

    test "an accepted expiration fans out on the owning ticket's decision.expired topic", %{dir: dir} do
      pid = start_store!(dir)
      :ok = Exchange.subscribe("ticket.979.agent.decision.expired")

      assert {:ok, %{decision: decision}} =
               request(pid, %{"question" => "Still waiting?", "blocking" => true})

      assert {:ok, %{status: :accepted}} =
               DecisionStore.expire(decision.decision_id, "agent_not_running", [], pid)

      assert_receive {:event,
                      %{
                        "event_type" => "decision_expired",
                        "decision_id" => decision_id,
                        "decision_version" => 1,
                        "data" => %{"reason_class" => "agent_not_running"},
                        topic: "ticket.979.agent.decision.expired",
                        digest_source: :orchestrator
                      } = expired_event},
                     500

      assert decision_id == decision.decision_id
      assert EventsDigest.render([expired_event], "979") =~ "ticket.979.agent.decision.expired"
    end
  end

  defp answerable_request(source_id) do
    %{
      "question" => "Deploy now?",
      "blocking" => true,
      "source_id" => source_id,
      "options" => [%{"id" => "ship", "label" => "Ship it"}]
    }
  end

  defp supervisor_basis(confidence) do
    %{
      confidence: confidence,
      alternatives_considered: ["Wait"],
      reversibility_belief: :reversible,
      policy_basis: %{
        authority: :supervisor_allowed,
        kind: "architecture",
        reversibility: :reversible,
        checks: %{authority_delegable: true, kind_allowed: true, reversibility_allowed: true},
        allow_non_reversible: false
      }
    }
  end

  defp audit_type(%DecisionEvent{type: type}), do: type
  defp audit_type(%Aiur.Decision{}), do: :requested

  defp correlated_queue_item(decision, action, attempt_id, queue_item_id) do
    %{
      id: queue_item_id,
      target_issue_identifier: decision.ticket.identifier,
      action_id: action.action_id,
      correlation: %{
        decision_id: decision.decision_id,
        decision_version: action.decision_version,
        action_id: action.action_id,
        attempt_id: attempt_id,
        actor: Map.get(action, :actor) || action |> Map.get(:answer, %{}) |> Map.get(:actor)
      }
    }
  end

  defp wait_for_decision(pid, decision_id, predicate, attempts \\ 100)

  defp wait_for_decision(_pid, _decision_id, _predicate, 0), do: flunk("decision did not reach expected state")

  defp wait_for_decision(pid, decision_id, predicate, attempts) do
    {:ok, decision} = DecisionStore.get(decision_id, pid)

    if predicate.(decision) do
      decision
    else
      Process.sleep(10)
      wait_for_decision(pid, decision_id, predicate, attempts - 1)
    end
  end

  defp wait_for_dispatch_count(pid, expected, attempts \\ 100)

  defp wait_for_dispatch_count(_pid, _expected, 0), do: flunk("dispatch count did not reach expected value")

  defp wait_for_dispatch_count(pid, expected, attempts) do
    if map_size(:sys.get_state(pid).dispatching) == expected do
      :ok
    else
      Process.sleep(10)
      wait_for_dispatch_count(pid, expected, attempts - 1)
    end
  end

  defp wait_for_named_process(name, previous, attempts \\ 100)

  defp wait_for_named_process(_name, _previous, 0), do: flunk("named process did not restart")

  defp wait_for_named_process(name, previous, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_named_process(name, previous, attempts - 1)
    end
  end

  defp unique_coordinator_name(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end
end
