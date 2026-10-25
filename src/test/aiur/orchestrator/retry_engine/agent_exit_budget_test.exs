defmodule Aiur.Orchestrator.RetryEngine.AgentExitBudgetTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State

  describe "agent exit on a local budget hold (#2339)" do
    test "a workspace-connectivity hold exit schedules a non-consuming reset_at-bounded retry" do
      issue_id = "issue-hold-exit"
      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      reason =
        {:workspace_github_connectivity_failed, "/workspaces/2339", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: {:aiur, :locally_held, hold}, hold: hold}}}}

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: "repo#hold-exit",
            started_at: DateTime.utc_now(),
            retry_attempt: 1,
            worker_host: "worker-a",
            workspace_path: "/workspaces/2339"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)

      retry = after_down.retry_attempts[issue_id]
      # The hold is non-consuming in every sense: `delay_type` is persisted as
      # `:local_budget_hold` (bounded by the hold's own `reset_at`, not the
      # exponential failure curve), and the failure attempt counter is left
      # unchanged (`retry_attempt: 1` stays 1 rather than becoming 2) so holds
      # can never push the stored attempt past `Config.max_retry_attempts()`.
      assert retry.attempt == 1
      assert retry.delay_type == :local_budget_hold
      assert retry.local_budget_hold == hold
      assert retry.error =~ "agent exited"
      assert retry.transient_reason == reason

      delay = max(0, retry.due_at_ms - System.monotonic_time(:millisecond))
      assert delay <= 31_000
      assert delay >= 1_000

      # A local-budget-hold retry is non-consuming, so it can never exhaust the
      # failure budget into `agent:error`.
      refute RetryEngine.failure_retry?(%{delay_type: :local_budget_hold})
      Process.cancel_timer(retry.timer_ref)
    end

    test "a raw hold exit reason takes the same non-consuming retry" do
      issue_id = "issue-hold-exit-raw"
      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
      reason = {:aiur, :locally_held, hold}

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: "repo#hold-exit-raw",
            started_at: DateTime.utc_now(),
            retry_attempt: 0,
            worker_host: nil,
            workspace_path: "/workspaces/2339"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)

      retry = after_down.retry_attempts[issue_id]
      assert retry.transient_reason == reason
      assert retry.error =~ "agent exited"
      # A fresh dispatch (`retry_attempt: 0`) schedules its first hold retry at
      # attempt 1 and the hold stays non-consuming.
      assert retry.attempt == 1
      assert retry.delay_type == :local_budget_hold
      assert retry.local_budget_hold == hold

      delay = max(0, retry.due_at_ms - System.monotonic_time(:millisecond))
      assert delay <= 31_000
      Process.cancel_timer(retry.timer_ref)
    end

    test "a local-budget-hold retry past max_retry_attempts never gives up into agent:error" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-HOLD-EXHAUST.agent.retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 3_600, :second)}

      next =
        RetryEngine.schedule_issue_retry(%State{}, "issue-hold-exhaust", Config.max_retry_attempts() + 1, %{
          identifier: "MT-HOLD-EXHAUST",
          delay_type: :local_budget_hold,
          local_budget_hold: hold,
          error: "agent exited: {:workspace_github_connectivity_failed, ...}"
        })

      # The retry is still scheduled; the give-up branch (which writes
      # `agent:error`) is skipped for `:local_budget_hold` because
      # `failure_retry?/1` is false.
      assert %{attempt: attempt, delay_type: :local_budget_hold, local_budget_hold: ^hold} =
               next.retry_attempts["issue-hold-exhaust"]

      assert attempt == Config.max_retry_attempts() + 1
      Process.cancel_timer(next.retry_attempts["issue-hold-exhaust"].timer_ref)
      refute_receive {:event, %{topic: "ticket.MT-HOLD-EXHAUST.agent.retry_exhausted"}}, 200
    end

    test "a hold-shaped agent exit at max_retry_attempts never gives up into agent:error" do
      # Drive the whole exit path, not `schedule_issue_retry/4` with a
      # hardcoded hold metadata: this is the #2339 regression pin. If
      # `exit_retry_metadata/2` were reverted to a consuming failure retry, the
      # hold at the attempt cap would hit the give-up branch and stamp
      # `agent:error`; this test asserts the retry stays scheduled (attempt
      # unchanged, `delay_type: :local_budget_hold`) and no `retry_exhausted`
      # alert fires.
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-HOLD-BOUNDARY.agent.retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue_id = "issue-hold-boundary"
      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      reason =
        {:workspace_github_connectivity_failed, "/workspaces/boundary", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: {:aiur, :locally_held, hold}, hold: hold}}}}

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: "MT-HOLD-BOUNDARY",
            started_at: DateTime.utc_now(),
            retry_attempt: Config.max_retry_attempts(),
            worker_host: "worker-a",
            workspace_path: "/workspaces/boundary"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)

      # Still scheduled at the same attempt (holds never advance the counter),
      # classified non-consuming, bounded by the hold's own reset_at.
      retry = after_down.retry_attempts[issue_id]
      assert retry.attempt == Config.max_retry_attempts()
      assert retry.delay_type == :local_budget_hold
      assert retry.local_budget_hold == hold
      assert retry.transient_reason == reason
      Process.cancel_timer(retry.timer_ref)

      refute_receive {:event, %{topic: "ticket.MT-HOLD-BOUNDARY.agent.retry_exhausted"}}, 200
    end

    test "a genuine failure exit at max_retry_attempts does give up" do
      # Symmetric control: at the same attempt cap, a non-hold exit reason must
      # still reach the give-up branch — the non-consuming hold path must not
      # mask genuine retry exhaustion.
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.MT-FAIL-BOUNDARY.agent.retry_exhausted")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue_id = "issue-fail-boundary"
      reason = {:workspace_git_metadata_unwritable, "/ws/.aiur-git-index-write-probe-1", {:git_index_probe_failed, 128}}

      state = %State{
        running: %{
          issue_id => %{
            ref: make_ref(),
            identifier: "MT-FAIL-BOUNDARY",
            started_at: DateTime.utc_now(),
            retry_attempt: Config.max_retry_attempts(),
            worker_host: "worker-a",
            workspace_path: "/ws"
          }
        },
        claimed: MapSet.new([issue_id]),
        dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
      }

      ref = state.running[issue_id].ref
      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)

      # The genuine failure at the cap gives up: the retry is removed and the
      # retry_exhausted alert fires (issue is moved to `error` in the tracker,
      # best-effort in this harness).
      refute Map.has_key?(after_down.retry_attempts, issue_id)
      assert_receive {:event, %{topic: "ticket.MT-FAIL-BOUNDARY.agent.retry_exhausted"}}, 500
    end
  end
end
