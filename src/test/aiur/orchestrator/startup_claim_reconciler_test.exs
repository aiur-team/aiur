defmodule Aiur.Orchestrator.StartupClaimReconcilerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Issue
  alias Aiur.Orchestrator.{StartupClaimReconciler, State}

  test "releases an orphaned in-progress claim to todo with a guarded update" do
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
    assert alert_opts[:reason] =~ "guarded update"
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

  test "protects an in-progress claim with a staged pid-less entry" do
    # A rate-limit-fallback or deactivated row is parked in `running` with
    # `pid: nil` while a replacement is admitted. It is still owned by this
    # generation and must protect its claim, not read as dead (#2076 review).
    issue = issue("2076", "in-progress")

    state = %State{
      running: %{
        "runtime-key" => %{identifier: issue.identifier, issue: issue, pid: nil}
      }
    }

    {result, [retained]} =
      StartupClaimReconciler.reconcile(state, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("a staged entry must protect its tracker claim")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("a staged entry must not alert") end
      )

    assert retained == issue
    assert result.startup_claim_reconciliation_complete?
  end

  test "releases a claim whose matching registry entry is no longer alive" do
    issue = issue("2076", "in-progress")
    {dead_pid, monitor} = spawn_monitor(fn -> :ok end)
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

  test "claims the current daemon boot before running the pass" do
    issue = issue("2076", "in-progress")
    parent = self()
    boot_id = Aiur.Boot.run_id()

    {state, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        read_boot_marker_fun: fn -> {:ok, nil} end,
        mark_boot_marker_fun: fn id ->
          send(parent, {:claimed_boot, id})
          :ok
        end,
        update_issue_state_fun: fn "2076", "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert_receive {:claimed_boot, ^boot_id}
    assert state.startup_claim_reconciliation_complete?
  end

  test "an Orchestrator-only restart never re-runs the pass against a live claim" do
    # The Orchestrator GenServer restarted in place: the agent tasks survived,
    # the boot marker still names the current boot, and this generation's
    # registry is empty. The pass must NOT release the surviving agent's claim
    # and fork the work (#2076 review P1).
    issue = issue("2076", "in-progress")
    boot_id = Aiur.Boot.run_id()

    {result, [retained]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        read_boot_marker_fun: fn -> {:ok, boot_id} end,
        mark_boot_marker_fun: fn _id -> flunk("a claimed boot must not re-run the pass") end,
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("an Orchestrator-only restart must not release a surviving claim")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("a skipped pass must not alert") end
      )

    assert retained == issue
    assert result.startup_claim_reconciliation_complete?
  end

  test "a new daemon boot (boot marker from an earlier boot) runs the pass again" do
    issue = issue("2076", "in-progress")

    {result, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        read_boot_marker_fun: fn -> {:ok, "an-earlier-boot-id"} end,
        update_issue_state_fun: fn "2076", "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert result.startup_claim_reconciliation_complete?
  end

  test "an unreadable boot marker fails closed and retains every claim" do
    issue = issue("2076", "in-progress")

    {result, [retained]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        read_boot_marker_fun: fn -> {:error, :corrupt_marker} end,
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("an unreadable marker must fail closed, never release")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("an unreadable marker must not alert") end
      )

    assert retained == issue
    refute result.startup_claim_reconciliation_complete?
  end

  test "a failed boot claim fails closed and retains every claim" do
    issue = issue("2076", "in-progress")

    {result, [retained]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        mark_boot_marker_fun: fn _id -> {:error, :disk_full} end,
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("an unclaimable boot must fail closed, never release")
        end,
        emit_alert_fun: fn _topic, _opts -> flunk("an unclaimable boot must not alert") end
      )

    assert retained == issue
    refute result.startup_claim_reconciliation_complete?
  end

  test "a failed release is retried across polls within the boot and latched at the cap" do
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
    assert failed_state.startup_claim_reconciliation_failures["2076"].attempts == 1
    assert log =~ "Failed to release orphaned startup claim"
    assert log =~ "retry 1/3"

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "guarded update"
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
    assert repeated_state.startup_claim_reconciliation_failures["2076"].attempts == 2
    assert repeated_log =~ "retry 2/3"
    refute_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}

    # The third failure reaches the per-ticket cap: the claim is latched and
    # the pass completes instead of reaping forever.
    final_log =
      capture_log(fn ->
        send(
          parent,
          {:final_result,
           StartupClaimReconciler.reconcile(repeated_state, [issue],
             update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
               {:error, :tracker_unavailable}
             end,
             emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
           )}
        )
      end)

    assert_receive {:final_result, {final_state, [^issue]}}
    assert final_state.startup_claim_reconciliation_complete?
    assert final_state.startup_claim_reconciliation_failures["2076"].attempts == 3
    assert final_log =~ "exhausted 3 attempts"
    refute_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}

    # The completed pass never re-attempts the latched ticket.
    assert {^final_state, [^issue]} =
             final_state
             |> Map.put(:startup_claim_reconciliation_complete?, false)
             |> reconcile_latched(issue)
  end

  defp reconcile_latched(state, issue) do
    StartupClaimReconciler.reconcile(state, [issue],
      read_boot_marker_fun: fn -> {:ok, Aiur.Boot.run_id()} end,
      mark_boot_marker_fun: fn _id -> :ok end,
      update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
        flunk("a latched ticket must never be re-attempted within the boot")
      end,
      emit_alert_fun: fn _topic, _opts -> :ok end
    )
  end

  test "a successful retry recovers the failure and resolves its attention" do
    issue = issue("2076", "in-progress")
    parent = self()

    {failed_state, [^issue]} =
      StartupClaimReconciler.reconcile(%State{}, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          {:error, :tracker_unavailable}
        end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed", _opts}

    {recovered_state, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(failed_state, [issue],
        update_issue_state_fun: fn "2076", "todo", "in-progress" -> :ok end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert recovered_state.startup_claim_reconciliation_complete?
    assert recovered_state.startup_claim_reconciliation_failures == %{}

    assert_receive {:alert, "ticket.2076.agent.startup_orphan_claim_released", _opts}

    assert_receive {:alert, "ticket.2076.agent.attention.startup_claim_reconciliation_failed.resolved", resolved_opts}
    refute resolved_opts[:needs_attention]
  end

  test "resolves a prior failure when a fresh snapshot no longer shows an orphan" do
    issue = issue("2076", "todo")

    state = %State{
      startup_claim_reconciliation_failures: %{
        "2076" => %{reason: :tracker_unavailable, attempts: 1}
      }
    }

    {reconciled, [^issue]} =
      StartupClaimReconciler.reconcile(state, [issue],
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          flunk("a non-orphan must not be updated")
        end,
        emit_alert_fun: fn topic, opts -> send(self(), {:alert, topic, opts}) end
      )

    assert reconciled.startup_claim_reconciliation_complete?
    assert reconciled.startup_claim_reconciliation_failures == %{}

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
