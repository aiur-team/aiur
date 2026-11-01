defmodule Aiur.Orchestrator.Deactivate.PauseRequestTest do
  use Aiur.TestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Events.{Exchange, Publisher, SubscriptionStore}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{EventTopics, PushRouting}
  alias Aiur.Orchestrator.RuntimeWatchdog
  alias Aiur.Workflow

  describe "pause-request topic parser (subscriber wiring)" do
    test "extracts the identifier from a valid agent.pause.request topic" do
      assert {:ok, "100"} =
               EventTopics.parse_pause_request_topic("ticket.100.agent.pause.request")

      assert {:ok, "ABC-42"} =
               EventTopics.parse_pause_request_topic("ticket.ABC-42.agent.pause.request")
    end

    test "rejects unrelated topics" do
      for unrelated <- [
            "ticket.100.agent.pause",
            "ticket.100.agent.pause.requested",
            "ticket.100.pr.review_comment",
            "system.main.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_pause_request_topic(unrelated)
      end
    end
  end

  describe "agent.pause.request awaits worker evidence" do
    test "running entry stays working until the worker confirms its pause" do
      issue_id = "issue-pause-1"
      identifier = "PAUSE-1"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :working
    end

    test "no-op when entry is already paused" do
      issue_id = "issue-pause-2"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, identifier)
    end

    test "no-op when entry is :deactivated (don't bring back from the dead)" do
      issue_id = "issue-pause-3"
      identifier = "PAUSE-3"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "human-review", identifier: identifier},
            started_at: DateTime.utc_now(),
            control: %{status: :deactivated}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      assert get_in(next.running, [issue_id, :control, :status]) == :deactivated
    end

    test "no-op when identifier isn't running" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      assert ^state = PushRouting.maybe_pause_on_request(state, "UNKNOWN")
    end

    test "does not stamp paused_at before the worker confirms the pause" do
      issue_id = "issue-pause-clock"
      identifier = "PAUSE-CLOCK"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: nil,
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      next = PushRouting.maybe_pause_on_request(state, identifier)
      entry = next.running[issue_id]

      assert entry.control.status == :working
      refute Map.has_key?(entry, :paused_at)
    end
  end

  describe "subscribe_for_declared_blocker/2 (called from agent_runner on declare)" do
    test "blockee gets unblock readiness and branch-ref subscriptions immediately" do
      blockee = "BSDB-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      topics = Enum.map(subs, fn entry -> entry["topic"] || entry[:topic] end)

      assert "ticket.#{blocker}.agent.unblocked" in topics,
             "blockee must subscribe to explicit unblock readiness"

      assert "ticket.#{blocker}.branch.push" in topics,
             "blockee must retain the blocker branch ref for fetch and inspection"
    end

    test "second call is idempotent (no duplicate subscriptions)" do
      blockee = "BSDB-idem-blockee-#{System.unique_integer([:positive])}"
      blocker = "BSDB-idem-blocker-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(blocker)
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)
      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)

      push_subs =
        Enum.filter(subs, fn e ->
          (e["topic"] || e[:topic]) == "ticket.#{blocker}.branch.push"
        end)

      assert length(push_subs) == 1
    end

    test "accepts integer identifiers (the GitHub API path)" do
      blockee = "BSDB-int-#{System.unique_integer([:positive])}"
      blocker_int = System.unique_integer([:positive])

      on_exit(fn ->
        :ok = SubscriptionStore.stop(blockee)
        :ok = SubscriptionStore.stop(to_string(blocker_int))
      end)

      :ok = Orchestrator.subscribe_for_declared_blocker(blockee, blocker_int)

      %{subscribed_to: subs} = SubscriptionStore.snapshot(blockee)
      topics = Enum.map(subs, fn e -> e["topic"] || e[:topic] end)

      assert "ticket.#{blocker_int}.branch.push" in topics
    end
  end

  describe "stall watchdog skips paused / deactivated entries" do
    test "stalled ci-wait worker with green exact-head CI hands off and does not retry" do
      issue_id = "stall-ci-ready"
      identifier = "STALL-CI-READY"
      stale_at = DateTime.add(DateTime.utc_now(), -600, :second)
      issue = %Issue{id: issue_id, identifier: identifier, state: "ci-wait"}

      entry = %{
        pid: spawn(fn -> Process.sleep(:infinity) end),
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
            pid: spawn_link(fn -> Process.sleep(:infinity) end),
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

      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

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
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

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
