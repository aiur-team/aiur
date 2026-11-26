defmodule Aiur.Orchestrator.RuntimeWatchdogStallTest do
  use Aiur.TestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.RuntimeWatchdog
  alias Aiur.Workflow

  describe "stall watchdog skips paused / deactivated entries" do
    test "stalled ci-wait worker with green exact-head CI hands off and does not retry" do
      issue_id = "stall-ci-ready"
      identifier = "STALL-CI-READY"
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}

      entry = %{
        pid:
          start_supervised!(
            {Task,
             fn ->
               receive do
                 :stop -> :ok
               end
             end}
          ),
        ref: nil,
        identifier: identifier,
        issue: issue,
        started_at: stale_at,
        last_codex_timestamp: stale_at,
        rework_head_sha: "head-green",
        session_execution: %{backend: "claude"},
        control: %{status: :working},
        lifecycle_fence: %{pending_item_ids: MapSet.new([1]), authoritative_state: "ci-wait"}
      }

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{},
        ci_lifecycle: %{poll_cache: %{identifier => %{decision: :passed, draft?: false, pr_number: 41, head_sha: "head-green", reviewed_head?: false}}}
      }

      previous_client = Application.get_env(:aiur, :github_client_module)
      Application.put_env(:aiur, :github_client_module, RecordingGitHubClient)
      RecordingGitHubClient.record_to(self())
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

      on_exit(fn ->
        if previous_client, do: Application.put_env(:aiur, :github_client_module, previous_client), else: Application.delete_env(:aiur, :github_client_module)
      end)

      on_exit(fn -> for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern) end)

      next = RuntimeWatchdog.apply_stall_check(state, 1)

      refute Map.has_key?(next.running, issue_id)
      refute Map.has_key?(next.retry_attempts, issue_id)
      assert next.retry_attempts == %{}
      assert_receive {:tracker_update, ^issue_id, "human-review", _opts}, 1_000
    end

    test "stalled ci-wait worker with green draft CI alerts once and does not hand off" do
      issue_id = "stall-ci-draft"
      identifier = "STALL-CI-DRAFT"
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.stalled")
      on_exit(fn -> for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern) end)
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}
      entry = %{pid: nil, ref: nil, identifier: identifier, issue: issue, started_at: stale_at, last_codex_timestamp: stale_at, rework_head_sha: "head-draft", control: %{status: :working}}

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        ci_lifecycle: %{poll_cache: %{identifier => %{decision: :passed, draft?: true, pr_number: 42, head_sha: "head-draft"}}},
        retry_attempts: %{}
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)

      assert Map.has_key?(next.running, issue_id)
      assert next.retry_attempts == %{}
      assert_received {:event, %{topic: "ticket.STALL-CI-DRAFT.agent.stalled"} = event}
      assert event["message"] == "worker stalled before marking PR ready; CI passed but PR is still a draft"

      repeated = RuntimeWatchdog.apply_stall_check(next, 1)
      assert repeated == next
      refute_received {:event, %{topic: "ticket.STALL-CI-DRAFT.agent.stalled"}}
    end

    test "stalled ci-wait worker with changes requested on the head does not hand off" do
      issue_id = "stall-ci-changes-requested"
      identifier = "STALL-CI-CHANGES-REQUESTED"
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}

      entry = %{
        pid: nil,
        ref: nil,
        identifier: identifier,
        issue: issue,
        started_at: stale_at,
        last_codex_timestamp: stale_at,
        rework_head_sha: "head-needs-changes",
        control: %{status: :working}
      }

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        ci_lifecycle: %{
          poll_cache: %{
            identifier => %{
              decision: :passed,
              draft?: false,
              pr_number: 43,
              head_sha: "head-needs-changes",
              reviewed_head?: true
            }
          }
        },
        retry_attempts: %{}
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)

      assert next == state
      refute_received {:tracker_update, ^issue_id, "human-review", _opts}
    end

    test "stalled ci-wait worker with failed CI and a matching PR head does not hand off" do
      issue_id = "stall-ci-failed"
      identifier = "STALL-CI-FAILED"
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}

      entry = %{
        pid: nil,
        ref: nil,
        identifier: identifier,
        issue: issue,
        started_at: stale_at,
        last_codex_timestamp: stale_at,
        rework_head_sha: "head-failed",
        control: %{status: :working}
      }

      state = %Orchestrator.State{
        running: %{issue_id => entry},
        ci_lifecycle: %{
          poll_cache: %{
            identifier => %{
              decision: :failed,
              draft?: false,
              pr_number: 44,
              head_sha: "head-failed",
              reviewed_head?: false
            }
          }
        },
        retry_attempts: %{}
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)

      assert next == state
      refute_received {:tracker_update, ^issue_id, "human-review", _opts}
    end

    test "stalled ci-wait worker with pending CI keeps waiting" do
      issue_id = "stall-ci-pending"
      identifier = "STALL-CI-PENDING"
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}
      entry = %{pid: nil, ref: nil, identifier: identifier, issue: issue, started_at: stale_at, last_codex_timestamp: stale_at, control: %{status: :working}}
      state = %Orchestrator.State{running: %{issue_id => entry}, ci_lifecycle: %{poll_cache: %{identifier => %{decision: :pending, pending_reason: :checks_pending}}}, retry_attempts: %{}}

      next = RuntimeWatchdog.apply_stall_check(state, 1)

      assert Map.has_key?(next.running, issue_id)
      assert next.retry_attempts == %{}
    end

    test "paused entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-paused"
      identifier = "STALL-P"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid:
              start_supervised!(
                {Task,
                 fn ->
                   receive do
                     :stop -> :ok
                   end
                 end}
              ),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      # 1ms timeout would trip on any entry whose elapsed > 1ms — but
      # the paused short-circuit must skip it BEFORE elapsed is computed.
      next = RuntimeWatchdog.apply_stall_check(state, 1)
      assert Map.has_key?(next.running, issue_id), "paused entry must not be restarted"
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert next.retry_attempts == %{}, "no retry should be scheduled"
    end

    test "deactivated entry with stale last_codex_timestamp is NOT restarted" do
      issue_id = "issue-stall-deact"
      identifier = "STALL-D"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)
      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
      assert next.retry_attempts == %{}
    end

    test "actively-working entry with stale last_codex_timestamp IS restarted" do
      issue_id = "issue-stall-working"
      identifier = "STALL-W"

      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.stalled")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      worker_pid =
        start_supervised!(
          {Task,
           fn ->
             receive do
               :stop -> :ok
             end
           end}
        )

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            session_execution: %{backend: "claude"},
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = RuntimeWatchdog.apply_stall_check(state, 1)
      refute Map.has_key?(next.running, issue_id), "working+stale entry must be restarted"

      assert %{identifier: ^identifier, error: "stalled" <> _} =
               Map.get(next.retry_attempts, issue_id)

      assert next.retry_attempts[issue_id].error =~ "without claude activity"

      receive_barrier({:event, %{topic: "ticket.STALL-W.agent.stalled"} = event})
      assert event["needs_attention"] == true
      assert event["message"] =~ "claude backend command (aiur-claude) made no progress"
      assert event["reason"] =~ "no-progress window"
    end

    test "claude-hook activity refreshes liveness so an active RC-claude entry is NOT stall-restarted" do
      # An RC-claude agent works via lifecycle hooks, which never produce a
      # codex update — so `last_codex_timestamp` stays at `started_at` while
      # the agent is busy. A hook firing must refresh liveness so the stall
      # watchdog does not kill a working agent.
      issue_id = "issue-hook-active"
      identifier = "STALL-HOOK"

      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

      worker_pid =
        start_supervised!(
          {Task,
           fn ->
             receive do
               :stop -> :ok
             end
           end}
        )

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker_pid,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: stale_at,
            last_codex_timestamp: stale_at,
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      # A claude hook fires for this agent -> liveness refreshed to now.
      refreshed = Orchestrator.note_agent_activity_state(state, identifier)

      next = RuntimeWatchdog.apply_stall_check(refreshed, 60_000)

      assert Map.has_key?(next.running, issue_id), "hook-active entry must NOT be stall-restarted"
      assert next.retry_attempts == %{}
    end

    test "note_agent_activity_state is a no-op for an unknown identifier" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert Orchestrator.note_agent_activity_state(state, "NOPE") == state
    end
  end
end
