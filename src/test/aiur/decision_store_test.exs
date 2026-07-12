defmodule Aiur.DecisionStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{Boot, DecisionEvent, DecisionLog, DecisionPubSub, DecisionStore}
  alias Aiur.Events.Exchange

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
      Keyword.merge([name: nil, filesystem_sync_fun: fn -> :ok end], opts)

    {:ok, pid} = DecisionStore.start_link(start_opts)
    pid
  end

  defp request(pid, payload, opts \\ []) do
    DecisionStore.request(payload, Keyword.merge([ticket: @ticket, source: @source], opts), pid)
  end

  defp answer(pid, decision_id, payload, opts \\ []) do
    DecisionStore.answer(
      decision_id,
      payload,
      Keyword.merge([actor: %{kind: :operator, id: "operator-1"}], opts),
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
      assert {:ok, [%DecisionEvent{type: :requested, data: ^decision}]} =
               DecisionStore.audit_history(decision.decision_id, pid)
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
      assert is_integer(record["event_id"])
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

    test "the next version with different content is accepted as an enrichment", %{dir: dir} do
      pid = start_store!(dir)
      base = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}

      assert {:ok, %{status: :accepted, decision: v1}} = request(pid, base)

      v2_payload = Map.merge(base, %{"question" => "Deploy now, revised?", "version" => 2})
      assert {:ok, %{status: :accepted, decision: v2}} = request(pid, v2_payload)

      assert v2.decision_id == v1.decision_id
      assert v2.version == 2
      assert {:ok, [^v1, ^v2]} = DecisionStore.history(v1.decision_id, pid)
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
      assert DecisionStore.health(pid2) == :writable
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

      pid = start_store!(dir, dispatcher: dispatcher, dispatch_delay_ms: 0)
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

    test "transient dispatch failure is durable and retried with a new attempt", %{dir: dir} do
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

      pid =
        start_store!(dir,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0,
          retry_delays_ms: [0]
        )

      assert {:ok, %{decision: decision}} = request(pid, answerable_request("answer-retry"))
      payload = %{"idempotency_key" => "retry-1", "expected_version" => 1, "custom_response" => "Proceed"}
      assert {:ok, _result} = answer(pid, decision.decision_id, payload)

      assert_receive {:attempted, 1, first_attempt}, 1_000
      assert_receive {:attempted, 2, second_attempt}, 1_000
      refute first_attempt == second_attempt

      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
      assert hd(settled.dispatch_attempts).failure_reason_class == "orchestrator_unavailable"
    end

    test "target-agent failure waits for an explicit idempotent retry", %{dir: dir} do
      parent = self()
      counter = :counters.new(1, [])

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
      refute_receive {:target_attempt, _, _}, 100

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(decision.decision_id, action.action_id, pid)
      assert_receive {:target_attempt, 2, true}, 1_000
      settled = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
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
      :ok = DecisionPubSub.subscribe()

      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, %{status: :accepted, decision: decision}} = request(pid, payload)

      assert_receive {:event, %{:topic => "ticket.979.agent.decision.requested", "question" => "Deploy now?"}}, 500
      assert_receive {:decision_changed, decision_id, 1}, 500
      assert decision_id == decision.decision_id
    end

    test "a duplicate does not fan out again", %{dir: dir} do
      pid = start_store!(dir)
      payload = %{"question" => "Deploy now?", "blocking" => true, "source_id" => "retry-1"}
      assert {:ok, _} = request(pid, payload)

      :ok = Exchange.subscribe("ticket.979.agent.decision.requested")
      assert {:ok, %{status: :duplicate}} = request(pid, payload)
      refute_receive {:event, %{topic: "ticket.979.agent.decision.requested"}}, 200
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

  defp audit_type(%DecisionEvent{type: type}), do: type
  defp audit_type(%Aiur.Decision{}), do: :requested

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
end
