defmodule Aiur.Orchestrator.StartupClaimReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Issue
  alias Aiur.Orchestrator.{StartupClaimReconciler, State}

  test "releases an orphaned in-progress claim to todo with compare-and-set evidence" do
    issue = issue("2076", "in-progress")
    parent = self()

    log =
      capture_log(fn ->
        result =
          StartupClaimReconciler.reconcile(%State{}, [issue],
            update_issue_state_fun: fn identifier, state_name, expected_state ->
              send(parent, {:transition, identifier, state_name, expected_state})
              :ok
            end,
            emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
          )

        send(parent, {:result, result})
      end)

    assert_receive {:transition, "2076", "todo", "in-progress"}
    assert_receive {:alert, "ticket.2076.agent.startup_orphan_claim_released", alert_opts}
    refute alert_opts[:needs_attention]
    assert alert_opts[:message] =~ "released"
    assert alert_opts[:reason] =~ "no live runtime"
    assert alert_opts[:severity] == "warning"

    assert_receive {:result, {state, [%Issue{state: "todo"}]}}
    assert state.startup_claim_reconciliation_complete?
    assert log =~ "Released orphaned startup claim to todo"
    assert log =~ "issue_id=issue-2076 issue_identifier=2076"
  end

  test "uses tracker-native lifecycle names for a guarded release" do
    issue = issue("LIN-2076", "In Progress")
    parent = self()

    {state, [%Issue{state: "Todo"}]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        active_states: ["Todo", "In Progress"],
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert_receive {:transition, "LIN-2076", "Todo", "In Progress"}
    assert state.startup_claim_reconciliation_complete?
  end

  test "protects an in-progress claim with a matching live runtime" do
    issue = issue("2076", "in-progress")

    state = %State{
      running: %{
        "runtime-key" => %{identifier: issue.identifier, issue: issue, pid: self()}
      }
    }

    {result, [retained]} =
      StartupClaimReconciler.reconcile(state, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("a live runtime must protect its tracker claim")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("a protected claim must not alert") end
      )

    assert retained == issue
    assert result.startup_claim_reconciliation_complete?
  end

  test "releases a claim whose matching registry entry is no longer alive" do
    issue = issue("2076", "in-progress")
    dead_pid = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^monitor, :process, ^dead_pid, :normal}

    state = %State{
      running: %{
        "runtime-key" => %{identifier: issue.identifier, issue: issue, pid: dead_pid}
      }
    }

    {result, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(state, [issue],
        update_issue_state_fun: fn "2076", "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert result.startup_claim_reconciliation_complete?
  end

  test "ignores tickets outside in-progress without writing another state" do
    issue = issue("2076", "todo")

    {state, [retained]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("startup reconciliation must only write in-progress claims")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("an unrelated state must not alert") end
      )

    assert retained == issue
    assert state.startup_claim_reconciliation_complete?
  end

  test "keeps a failed orphan release eligible for a later poll and surfaces the failure" do
    issue = issue("2076", "in-progress")
    parent = self()

    log =
      capture_log(fn ->
        result =
          StartupClaimReconciler.reconcile(%State{}, [issue],
            update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
              {:error, :tracker_unavailable}
            end,
            emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
          )

        send(parent, {:failed_result, result})
      end)

    assert_receive {:failed_result, {failed_state, [^issue]}}
    refute failed_state.startup_claim_reconciliation_complete?
    assert log =~ "Failed to release orphaned startup claim"
    assert log =~ "issue_id=issue-2076 issue_identifier=2076"

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "tracker_unavailable"

    repeated_log =
      capture_log(fn ->
        result =
          StartupClaimReconciler.reconcile(failed_state, [issue],
            update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
              {:error, :tracker_unavailable}
            end,
            emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
          )

        send(parent, {:repeated_result, result})
      end)

    assert_receive {:repeated_result, {repeated_state, [^issue]}}
    refute repeated_state.startup_claim_reconciliation_complete?
    assert repeated_log == ""
    refute_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}

    {recovered_state, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(repeated_state, [issue],
        update_issue_state_fun: fn "2076", "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert recovered_state.startup_claim_reconciliation_complete?
    assert recovered_state.startup_claim_reconciliation_failures == MapSet.new()

    assert_receive {:alert, "ticket.2076.agent.startup_orphan_claim_released", _opts}

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed.resolved", resolved_opts}
    refute resolved_opts[:needs_attention]
  end

  test "latches a release failure by ticket while retaining the latest reason" do
    issue = issue("2076", "in-progress")
    parent = self()

    {failed_state, [^issue]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          {:error, :first_reason}
        end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}

    repeated_log =
      capture_log(fn ->
        {repeated_state, [^issue]} =
          StartupClaimReconciler.reconcile(failed_state, [issue],
            update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
              {:error, :changed_reason}
            end,
            emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
          )

        assert repeated_state.startup_claim_reconciliation_failures ==
                 MapSet.new([{"2076", ":changed_reason"}])
      end)

    assert repeated_log == ""
    refute_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}
  end

  test "resolves a prior failure when a fresh snapshot no longer shows an orphan" do
    issue = issue("2076", "todo")

    state = %State{
      startup_claim_reconciliation_failures: MapSet.new([{"2076", ":tracker_unavailable"}])
    }

    {reconciled, [^issue]} =
      StartupClaimReconciler.reconcile(state, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("a non-orphan must not be updated")
        end,
        emit_alert_fun: fn topic, opts -> send(self(), {:alert, topic, opts}) end
      )

    assert reconciled.startup_claim_reconciliation_complete?
    assert reconciled.startup_claim_reconciliation_failures == MapSet.new()

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed.resolved", opts}
    assert opts[:reason] =~ "no longer reports an orphaned"
  end

  test "a completed startup pass never releases claims discovered on later polls" do
    {complete_state, []} = StartupClaimReconciler.reconcile(%State{}, [])
    issue = issue("later", "in-progress")

    assert {^complete_state, [^issue]} =
             StartupClaimReconciler.reconcile(complete_state, [issue],
               update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
                 flunk("startup reconciliation is one-shot after successful completion")
               end
             )
  end

  defp issue(identifier, state) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Ticket #{identifier}",
      state: state
    }
  end
end
