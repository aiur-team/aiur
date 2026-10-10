defmodule Aiur.DecisionJournalOutcomeTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.{DecisionStore, Journal}

  @moduletag :tmp_dir
  @actor %{kind: :operator, id: "operator-3274"}
  @ticket %{identifier: "3274", title: "Journal outcomes", url: "https://github.com/aiur-team/aiur/issues/3274"}

  defmodule FileOps do
    def write(fd, line) do
      event = Jason.decode!(line)

      fault = reserve_fault(event)

      case fault do
        :write_error ->
          {:error, :enospc}

        :missing ->
          :ok

        :partial_error ->
          :ok = :file.write(fd, binary_part(line, 0, 20))
          {:error, :enospc}

        :written_error ->
          :ok = :file.write(fd, line)
          {:error, :enospc}

        :corrupt ->
          :file.write(fd, "corrupt complete record\n")

        :duplicate ->
          :file.write(fd, line <> line)

        :invalid_transition ->
          {:ok, invalid} =
            Aiur.DecisionEvent.new(:delivered, event["decision_id"], event["decision_version"], %{action_id: "act_missing", attempt_id: "attempt-missing", queue_item_id: 7},
              event_id: "invalid-transition",
              run_id: "journal-test"
            )

          :file.write(fd, Jason.encode!(Aiur.DecisionEvent.to_json_safe(invalid)) <> "\n")

        _other ->
          :file.write(fd, line)
      end
    end

    defp reserve_fault(event) do
      Agent.get_and_update(__MODULE__, fn state ->
        fault = if state.type == event["event_type"] and state.remaining > 0, do: state.mode, else: :none
        remaining = if fault == :none, do: state.remaining, else: state.remaining - 1
        {fault, %{state | remaining: remaining, last: fault, writes: state.writes ++ [event]}}
      end)
    end

    def sync(fd) do
      case Agent.get(__MODULE__, & &1.last) do
        mode when mode in [:sync_error, :missing, :corrupt, :duplicate, :invalid_transition] -> {:error, :timeout}
        _other -> :file.sync(fd)
      end
    end
  end

  setup %{tmp_dir: dir} do
    start_supervised!(%{id: FileOps, start: {Agent, :start_link, [fn -> %{type: nil, remaining: 0, mode: :none, last: :none, writes: []} end, [name: FileOps]]}})
    %{dir: dir}
  end

  defp inject(type, mode, remaining \\ 1) do
    Agent.update(FileOps, &%{&1 | type: type, mode: mode, remaining: remaining})
  end

  test "write error before bytes is failed", %{dir: dir} do
    inject(nil, :write_error)
    path = Path.join(dir, "log")
    assert {:failed, :enospc} = Journal.append(path, %{"event_id" => "write-error"}, file_ops: FileOps)
    assert File.read!(path) == ""
  end

  test "sync error after write is ambiguous and reconciles as accepted", %{dir: dir} do
    inject(nil, :sync_error)
    path = Path.join(dir, "log")
    assert {:ambiguous, :timeout} = Journal.append(path, %{"event_id" => "sync-error"}, file_ops: FileOps)
    assert :accepted = Journal.reconcile_ambiguous(path, "sync-error")
    assert :failed = Journal.reconcile_ambiguous(path, "absent")
  end

  test "partial write errors are ambiguous and replay repairs their torn tail", %{dir: dir} do
    inject(nil, :partial_error)
    path = Path.join(dir, "log")
    assert {:ambiguous, :enospc} = Journal.append(path, %{"event_id" => "partial-write-error"}, file_ops: FileOps)
    assert byte_size(File.read!(path)) == 20
    assert :failed = Journal.reconcile_ambiguous(path, "partial-write-error")
    assert File.read!(path) == ""
  end

  for {mode, write_count} <- [sync_error: 1, missing: 2, partial_error: 2, written_error: 1] do
    test "ambiguous #{mode} request is accepted exactly once", %{dir: dir} do
      inject("requested", unquote(mode))
      pid = store!(dir)
      assert {:ok, %{status: :accepted, decision: decision}} = request(pid)
      assert {:ok, [event], nil} = Journal.replay(Path.join(dir, "decisions.ndjson"), &{:ok, &1})
      assert event["decision_id"] == decision.decision_id
      writes = Agent.get(FileOps, & &1.writes)
      assert length(writes) == unquote(write_count)
      assert Enum.uniq(Enum.map(writes, & &1["event_id"])) == [event["event_id"]]
      assert DecisionStore.health(pid) == :writable
    end
  end

  test "corrupt complete record during reconciliation holds subsequent mutations", %{dir: dir} do
    inject("requested", :corrupt)
    pid = store!(dir)
    assert {:error, {:append_failed, {:journal_ambiguous, event, {:corrupt, 1, _reason}}}} = request(pid)
    assert {:journal_ambiguous, event_id, {:corrupt, 1, _reason}} = DecisionStore.health(pid)
    assert event_id == event.event_id
    assert {:error, {:store_unavailable, _health}} = request(pid)
    assert length(Agent.get(FileOps, & &1.writes)) == 1
  end

  for mode <- [:duplicate, :invalid_transition] do
    test "ambiguous #{mode} records hold journal mutations", %{dir: dir} do
      inject("requested", unquote(mode))
      pid = store!(dir)
      assert {:error, {:append_failed, {:journal_ambiguous, _event, {:corrupt, _line, {:invalid_transition, _reason}}}}} = request(pid)
      assert {:journal_ambiguous, _id, {:corrupt, _line, {:invalid_transition, _reason}}} = DecisionStore.health(pid)
      assert {:error, {:store_unavailable, _health}} = request(pid)
      assert length(Agent.get(FileOps, & &1.writes)) == 1
    end
  end

  test "ambiguous lifecycle write updates its projection once", %{dir: dir} do
    pid = store!(dir)
    assert {:ok, %{decision: decision}} = request(pid)
    inject("answer_recorded", :sync_error)
    assert {:ok, %{status: :accepted}} = answer(pid, decision)
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.map(audit, & &1.type) == [:requested, :answer_recorded]
    assert length(Agent.get(FileOps, & &1.writes)) == 2
  end

  test "ambiguous enrichment updates the context once", %{dir: dir} do
    pid = store!(dir)
    assert {:ok, %{decision: decision}} = request(pid)
    inject("enriched", :sync_error)

    assert {:ok, %{status: :accepted, decision: updated}} =
             DecisionStore.enrich(decision.decision_id, %{"context" => %{"short_summary" => "New evidence"}}, [actor: %{kind: :supervisor, id: "supervising-agent"}, expected_version: 1], pid)

    assert updated.context.short_summary == "New evidence"
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    assert Enum.map(audit, & &1.type) == [:requested, :enriched]
    assert length(Agent.get(FileOps, & &1.writes)) == 2
  end

  for mode <- [:write_error, :corrupt, :duplicate, :invalid_transition] do
    test "follow-up #{mode} is alerted and retried without redispatch", %{dir: dir} do
      parent = self()
      log_root = configure_alert_log(dir)

      scheduler = fn store, message, _delay ->
        send(parent, {:scheduled, store, message})
        make_ref()
      end

      dispatcher = fn decision, _opts ->
        send(parent, {:dispatched, decision.revision_sequence})
        {:no_longer_applicable, :missing}
      end

      pid = store!(dir, dispatch_scheduler: scheduler, dispatcher: dispatcher, retry_delays_ms: [0, 0])
      assert {:ok, %{decision: decision}} = request(pid)
      assert {:ok, %{action: original}} = answer(pid, decision)
      inject("follow_up_required", unquote(mode))
      assert {:ok, %{action: revision}} = revise(pid, decision, original)
      receive_barrier({:scheduled, ^pid, {:dispatch_action, first_fence, first_retry}})
      # The answer's stale fence is harmless; drive both queued actions causally.
      send(pid, {:dispatch_action, first_fence, first_retry})
      receive_barrier({:scheduled, ^pid, {:dispatch_action, revision_fence, revision_retry}})
      send(pid, {:dispatch_action, revision_fence, revision_retry})
      receive_barrier({:scheduled, ^pid, {:retry_follow_up_append, key}})
      assert {:lifecycle_append_failed, :follow_up_required, _reason} = DecisionStore.health(pid)
      assert {:error, {:store_unavailable, _health}} = request(pid)
      topic = "ticket.3274.agent.attention.decision-lifecycle-persistence-#{String.replace(revision.action_id, "_", "-")}"
      assert [_alert] = Aiur.AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) |> Enum.filter(&(&1["topic"] == topic))

      path = Path.join(dir, "decisions.ndjson")

      if unquote(mode) in [:duplicate, :invalid_transition] do
        send(pid, {:retry_follow_up_append, key})
        assert {:lifecycle_append_failed, :follow_up_required, _reason} = DecisionStore.health(pid)
        assert {:ok, before_repair} = DecisionStore.get(decision.decision_id, pid)
        refute Map.has_key?(before_repair.revision_follow_ups, revision.action_id)
        receive_barrier({:scheduled, ^pid, {:retry_follow_up_append, ^key}})
      end

      case unquote(mode) do
        :corrupt ->
          File.write!(path, String.replace(File.read!(path), "corrupt complete record\n", ""))

        :duplicate ->
          File.write!(path, Enum.join(Enum.uniq(String.split(File.read!(path), "\n", trim: true)), "\n") <> "\n")

        :invalid_transition ->
          lines = File.read!(path) |> String.split("\n", trim: true) |> Enum.reject(&(Jason.decode!(&1)["event_id"] == "invalid-transition"))
          File.write!(path, Enum.join(lines, "\n") <> "\n")

        :write_error ->
          :ok
      end

      send(pid, {:retry_follow_up_append, key})
      assert DecisionStore.health(pid) == :writable
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(&1.type == :follow_up_required)) == 1
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert Map.has_key?(current.revision_follow_ups, revision.action_id)
      assert_received {:dispatched, 1}
      refute_received {:dispatched, _sequence}

      assert Aiur.AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)
             |> Enum.filter(&(&1["topic"] == topic)) == []

      inject("follow_up_handled", :write_error)

      newest_action_id =
        if unquote(mode) == :write_error do
          assert {:error, :enospc} = DecisionStore.handle_revision_follow_up(decision.decision_id, revision.action_id, [actor: @actor, detail: "Handled manually"], pid)
          revision.action_id
        else
          assert {:ok, %{action: newest}} =
                   DecisionStore.revise(
                     decision.decision_id,
                     %{
                       "idempotency_key" => "second-revision",
                       "expected_version" => 1,
                       "expected_action_id" => revision.action_id,
                       "expected_revision_sequence" => 1,
                       "custom_response" => "Different direction",
                       "rationale" => "More evidence"
                     },
                     [actor: @actor],
                     pid
                   )

          newest.action_id
        end

      receive_barrier({:scheduled, ^pid, {:retry_follow_up_append, handled_key}})
      assert {:lifecycle_append_failed, :follow_up_handled, :enospc} = DecisionStore.health(pid)
      send(pid, {:retry_follow_up_append, handled_key})
      assert DecisionStore.health(pid) == :writable
      assert {:ok, current} = DecisionStore.get(decision.decision_id, pid)
      assert current.active_action_id == newest_action_id
      assert %DateTime{} = current.revision_follow_ups[revision.action_id].handled_at
      assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
      assert Enum.count(audit, &(&1.type == :follow_up_handled)) == 1
      if unquote(mode) == :write_error, do: assert(List.last(audit).data.actor == @actor)
      refute_received {:dispatched, _sequence}
    end
  end

  test "follow-up retry exhaustion keeps writes held and the attention open", %{dir: dir} do
    parent = self()
    log_root = configure_alert_log(dir)

    scheduler = fn store, message, _delay ->
      send(parent, {:scheduled, store, message})
      make_ref()
    end

    pid = store!(dir, dispatch_scheduler: scheduler, dispatcher: fn _, _ -> {:no_longer_applicable, :missing} end, retry_delays_ms: [0])
    assert {:ok, %{decision: decision}} = request(pid)
    assert {:ok, %{action: original}} = answer(pid, decision)
    inject("follow_up_required", :write_error, 10)
    assert {:ok, %{action: revision}} = revise(pid, decision, original)
    receive_barrier({:scheduled, ^pid, {:dispatch_action, _original_fence, _original_retry}})
    receive_barrier({:scheduled, ^pid, {:dispatch_action, fence, retry}})
    send(pid, {:dispatch_action, fence, retry})
    receive_barrier({:scheduled, ^pid, {:retry_follow_up_append, key}})
    send(pid, {:retry_follow_up_append, key})
    assert {:lifecycle_append_failed, :follow_up_required, :enospc} = DecisionStore.health(pid)
    assert {:error, {:store_unavailable, _health}} = request(pid)
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, pid)
    refute Enum.any?(audit, &(&1.type == :follow_up_required))
    assert Enum.count(Agent.get(FileOps, & &1.writes), &(&1["event_type"] == "follow_up_required")) == 2
    refute_received {:scheduled, ^pid, {:retry_follow_up_append, _key}}
    topic = "ticket.3274.agent.attention.decision-lifecycle-persistence-#{String.replace(revision.action_id, "_", "-")}"
    assert [_alert] = Aiur.AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true) |> Enum.filter(&(&1["topic"] == topic))
  end

  for held_kind <- [:scheduled, :in_flight] do
    test "follow-up recovery preserves unrelated #{held_kind} dispatch work", %{dir: dir} do
      parent = self()

      scheduler = fn store, message, _delay ->
        send(parent, {:scheduled, store, message})
        make_ref()
      end

      dispatcher = fn decision, opts ->
        if decision.question == "Unrelated?" do
          send(parent, {:unrelated_dispatch, self()})

          receive do
            :finish -> {:ok, %{status: :accepted, item: %{id: 3274, correlation: %{attempt_id: opts[:attempt_id]}}}}
          end
        else
          send(parent, :revision_dispatch)
          {:no_longer_applicable, :missing}
        end
      end

      pid = store!(dir, dispatch_scheduler: scheduler, dispatcher: dispatcher, retry_delays_ms: [0])
      assert {:ok, %{decision: decision}} = request(pid)
      assert {:ok, %{action: original}} = answer(pid, decision)
      assert {:ok, %{decision: unrelated}} = request(pid, "Unrelated?", %{@ticket | identifier: "3275"})
      assert {:ok, _answer} = answer(pid, unrelated)
      unrelated_id = unrelated.decision_id
      receive_barrier({:scheduled, ^pid, {:dispatch_action, %{decision_id: ^unrelated_id} = unrelated_fence, retry}})

      task =
        if unquote(held_kind) == :in_flight do
          send(pid, {:dispatch_action, unrelated_fence, retry})
          receive_barrier({:unrelated_dispatch, task_pid})
          task_pid
        end

      inject("follow_up_required", :write_error)
      assert {:ok, _revision} = revise(pid, decision, original)
      # Discard the original answer's stale fence, then drive the revision.
      decision_id = decision.decision_id
      receive_barrier({:scheduled, ^pid, {:dispatch_action, %{decision_id: ^decision_id}, _original_retry}})
      receive_barrier({:scheduled, ^pid, {:dispatch_action, %{decision_id: ^decision_id} = fence, revision_retry}})
      send(pid, {:dispatch_action, fence, revision_retry})
      receive_barrier({:scheduled, ^pid, {:retry_follow_up_append, key}})
      assert {:lifecycle_append_failed, _, _} = DecisionStore.health(pid)
      :ok = Aiur.DecisionPubSub.subscribe()

      if unquote(held_kind) == :in_flight do
        :erlang.trace(pid, true, [:receive])
        send(task, :finish)
        receive_barrier({:trace, ^pid, :receive, {:dispatch_result, %{decision_id: ^unrelated_id}, _result}})
        :erlang.trace(pid, false, [:receive])
      else
        send(pid, {:dispatch_action, unrelated_fence, retry})
      end

      assert {:ok, before_recovery} = DecisionStore.get(unrelated_id, pid)
      assert before_recovery.delivery_status == :pending
      refute_received {:unrelated_dispatch, _task}
      send(pid, {:retry_follow_up_append, key})

      if unquote(held_kind) == :scheduled do
        receive_barrier({:unrelated_dispatch, task_pid})
        send(task_pid, :finish)
      end

      receive_barrier({:decision_changed, ^unrelated_id, _version})
      assert {:ok, recovered} = DecisionStore.get(unrelated_id, pid)
      assert recovered.delivery_status == :queued
      assert length(recovered.dispatch_attempts) == 1
      assert_received :revision_dispatch
      refute_received :revision_dispatch
      refute_received {:unrelated_dispatch, _task}
    end
  end

  defp configure_alert_log(dir) do
    log_root = Path.join(dir, "alerts")
    Aiur.TestSupport.put_runtime_state_dir!(log_root)
    old_log = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(log_root, "aiur.log"))
    on_exit(fn -> Application.put_env(:aiur, :log_file, old_log) end)
    log_root
  end

  defp store!(dir, opts \\ []) do
    defaults = [
      name: nil,
      state_dir: dir,
      file_ops: FileOps,
      filesystem_sync_fun: fn -> :ok end,
      dispatch_delay_ms: 60_000,
      reconcile_delay_ms: 60_000,
      revision_follow_up_projector: fn _, _ -> :ok end
    ]

    start_supervised!({DecisionStore, Keyword.merge(defaults, opts)})
  end

  defp request(pid, question \\ "Deploy now?", ticket \\ @ticket) do
    DecisionStore.request(
      %{"question" => question, "blocking" => true, "options" => [%{"id" => "ship", "label" => "Ship"}]},
      [ticket: ticket, source: %{agent_id: "agent-3274", session_id: "session-3274", event_id: nil}],
      pid
    )
  end

  defp answer(pid, decision) do
    DecisionStore.answer(decision.decision_id, %{"idempotency_key" => "original", "expected_version" => 1, "option_id" => "ship"}, [actor: @actor], pid)
  end

  defp revise(pid, decision, original) do
    DecisionStore.revise(
      decision.decision_id,
      %{
        "idempotency_key" => "revision",
        "expected_version" => 1,
        "expected_action_id" => original.action_id,
        "expected_revision_sequence" => 0,
        "custom_response" => "Hold",
        "rationale" => "New evidence"
      },
      [actor: @actor],
      pid
    )
  end
end
