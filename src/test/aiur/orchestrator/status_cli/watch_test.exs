Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliWatchTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{Asks, Issue, RepoBase}

  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  alias Aiur.Orchestrator.StatusCLI, as: AgentControlCLI

  describe "watch" do
    setup do
      :persistent_term.erase({Aiur.AgentControlCLI, :watch_baseline})

      root = Aiur.TestSupport.tmp_root!("aiur-watch")
      File.mkdir_p!(root)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

      {:ok, watch_root: root}
    end

    test "reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
      Process.unregister(Orchestrator)

      try do
        output = capture_io(fn -> AgentControlCLI.watch() end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: watch query failed because the orchestrator is not running"
        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      after
        Process.register(pid, Orchestrator)
      end
    end

    test "distinguishes a bounded query timeout", %{orchestrator: pid} do
      :sys.suspend(pid)

      try do
        output = capture_io(fn -> AgentControlCLI.watch(status_timeout_ms: 1) end)

        assert output =~ "__AIUR_CONTROL_ERROR__:aiur: watch query timed out after 1ms; outcome is unknown"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      after
        :sys.resume(pid)
      end
    end

    test "full board renders state, complexity, and activity per agent", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  labels: ["agent:in-progress", "complexity:3"],
                  last_codex_message: "running mix test"
                )
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "TICKET  STATE         CX  AGE     DOING"
      assert output =~ ~r/#44\s+agent:in-progress\s+3\s/
      assert output =~ "running mix test"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "watch distinguishes provider startup and retry from a live turn", %{orchestrator: pid, watch_root: root} do
      starting = watch_entry("issue-2895", "repo#2895", state: "in-progress") |> Map.put(:session_id, nil)

      retry = %{
        identifier: "repo#2896",
        attempt: 1,
        due_at_ms: System.monotonic_time(:millisecond) + 10_000,
        error: "startup failed: {:port_exit, 23}"
      }

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-2895" => starting}, retry_attempts: %{"issue-2896" => retry}}
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert output =~ ~r/#2895\s+agent:in-progress\s/
      assert output =~ "(starting provider; no live turn yet)"
      assert output =~ ~r/#2896\s+agent:retrying\s/
      assert output =~ "startup failed: {:port_exit, 23}"
    end

    test "status and watch surface persisted open blocking operator asks", %{watch_root: root} do
      asks_root = Aiur.TestSupport.tmp_root!("aiur-status-asks")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        Aiur.TestCleanup.rm_rf!(asks_root)
      end)

      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

      assert {:ok, ask} =
               Asks.create("owner/repo", %{
                 title: "Enable CI readiness inspection",
                 urgency: "high",
                 blocking: true
               })

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking)"
      assert status =~ ask["id"]
      assert status =~ "from executor at #{ask["created_at"]}"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASK #{ask["id"]}"
      assert watch =~ "Enable CI readiness inspection"

      assert {:ok, _} = Asks.resolve("owner/repo", ask["id"])
      refute capture_io(fn -> AgentControlCLI.status() end) =~ ask["id"]
      refute capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end) =~ ask["id"]
    end

    test "status and watch make an unreadable operator ask store actionable", %{watch_root: root} do
      asks_root = Aiur.TestSupport.tmp_root!("aiur-status-asks")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, asks_root)

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
        Aiur.TestCleanup.rm_rf!(asks_root)
      end)

      restore_workflow_file_after_test()
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
      :ok = RepoBase.ensure_state_tree("owner/repo")

      File.write!(
        RepoBase.asks_path("owner/repo"),
        Jason.encode!(%{
          "id" => "ask_orphan",
          "status" => "done",
          "resolved_at" => "2026-08-08T12:00:00Z",
          "resolved_by" => "executor",
          "note" => nil
        }) <> "\n"
      )

      status = capture_io(fn -> AgentControlCLI.status() end)
      assert status =~ "OPERATOR ASKS (blocking) UNAVAILABLE"
      assert status =~ "could not read durable ask record 1"
      assert status =~ "orphan_done"

      watch = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)
      assert watch =~ "ACTIONABLE"
      assert watch =~ "BLOCKING ASKS UNAVAILABLE"
    end

    test "empty board reports no active agents", %{watch_root: root} do
      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "(no active agents)"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board puts the global pause banner before the table", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state -> %{state | globally_paused: true, global_pause: %{paused_at: nil, source: "dashboard"}} end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "GLOBALLY PAUSED (set by dashboard)"
      assert String.starts_with?(output, "GLOBALLY PAUSED")
    end

    test "full board surfaces prewarm: warming while the base warms", %{watch_root: root} do
      with_prewarm_enabled()
      with_repo_base_phase(:building)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "PREWARM prewarm: warming phase=building"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end

    test "full board shows paused label override for idle active-state tickets", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | last_polled_issues: %{
              "issue-46" => %Issue{
                id: "issue-46",
                identifier: "repo#46",
                state: "todo",
                title: "Paused todo",
                paused: true,
                labels: ["agent:todo", "agent:paused", "complexity:2"]
              }
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+agent:todo,agent:paused\s+2\s/
      assert output =~ "(paused: operator)"
    end

    test "watch shows paused retry causes and reports a reason-only change", %{orchestrator: pid, watch_root: root} do
      retry = %Issue{
        id: "issue-47",
        identifier: "repo#47",
        state: "todo",
        title: "Retrying",
        paused: true,
        labels: ["agent:todo", "agent:paused"]
      }

      due_at_ms = System.monotonic_time(:millisecond) + 240_000

      set_retry = fn error ->
        :sys.replace_state(pid, fn state ->
          %{
            state
            | last_polled_issues: %{retry.id => retry},
              retry_attempts: %{
                retry.id => %{identifier: retry.identifier, attempt: 1, due_at_ms: due_at_ms, error: error}
              }
          }
        end)
      end

      set_retry.("tracker 403")
      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "(paused: operator; transient: tracker 403, retry ~4m)"

      set_retry.("provider unavailable")
      changed = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert changed =~ "#47"
      assert changed =~ "(paused: operator; transient: provider unavailable, retry ~4m)"
    end

    test "changes mode prints a row once, then only when its state shifts", %{orchestrator: pid, watch_root: root} do
      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress")}}
      end)

      first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert first =~ "#44"

      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert second =~ "(no changes)"
      refute second =~ "#44"

      :sys.replace_state(pid, fn state ->
        %{state | running: %{"issue-44" => watch_entry("issue-44", "repo#44", state: "rework")}}
      end)

      third = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)
      assert third =~ "#44"
      assert third =~ "rework"
    end

    test "changes mode diffs each agent independently", %{orchestrator: pid, watch_root: root} do
      both = fn s45 ->
        %{
          "issue-44" => watch_entry("issue-44", "repo#44", state: "in-progress"),
          "issue-45" => watch_entry("issue-45", "repo#45", state: s45)
        }
      end

      :sys.replace_state(pid, fn state -> %{state | running: both.("in-progress")} end)
      _first = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      # Only #45 shifts state; #44 holds steady.
      :sys.replace_state(pid, fn state -> %{state | running: both.("rework")} end)
      second = capture_io(fn -> AgentControlCLI.watch(mode: :changes, roots: [root], log_roots: [root]) end)

      assert second =~ "#45"
      assert second =~ "rework"
      refute second =~ "#44"
    end

    test "actionable section flags stuck agents and PR-ready tickets", %{orchestrator: pid, watch_root: root} do
      stale_ts = DateTime.add(DateTime.utc_now(), -1_200, :second)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-44" =>
                watch_entry("issue-44", "repo#44",
                  state: "in-progress",
                  last_codex_timestamp: stale_ts,
                  last_codex_message: "compiling"
                ),
              "issue-45" => watch_entry("issue-45", "repo#45", state: "human-review")
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ ~r/#44 stuck/
      assert output =~ ~r/#45 human-review · needs review\/merge/
    end

    test "actionable section surfaces an unanswered operator-decision question", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")

      File.write!(
        ledger,
        Jason.encode!(%{
          "event" => "alert",
          "name" => "ticket.934.agent.attention.scope-question",
          "topic" => "ticket.934.agent.attention.scope-question",
          "message" => "Executor decision required",
          "reason" => "Executor decision required: Should this facade target change?",
          "severity" => "warning",
          "needs_attention" => true,
          "source_ticket_id" => "934",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }) <> "\n"
      )

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger]) end)

      assert output =~ "ACTIONABLE"
      assert output =~ "#934"
      assert output =~ "Executor decision required: Should this facade target change?"
    end

    test "resolved operator decisions leave the actionable section", %{watch_root: root} do
      ledger = Path.join(root, "ledger.ndjson")
      initial_at = DateTime.utc_now() |> DateTime.to_iso8601()
      resolved_at = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      attention = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question",
        "topic" => "ticket.934.agent.attention.scope-question",
        "message" => "Executor decision required",
        "reason" => "Executor decision required: Should this facade target change?",
        "severity" => "warning",
        "needs_attention" => true,
        "source_ticket_id" => "934",
        "timestamp" => initial_at
      }

      resolved = %{
        "event" => "alert",
        "name" => "ticket.934.agent.attention.scope-question.resolved",
        "topic" => "ticket.934.agent.attention.scope-question.resolved",
        "message" => "Executor decision updated",
        "reason" => "Executor decision resolved.",
        "severity" => "info",
        "needs_attention" => false,
        "source_ticket_id" => "934",
        "timestamp" => resolved_at
      }

      File.write!(ledger, Jason.encode!(attention) <> "\n" <> Jason.encode!(resolved) <> "\n")

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, ledger_paths: [ledger], blocking_asks: []) end)

      refute output =~ "ACTIONABLE"
    end

    test "CI-wait remains visible as an automatic gate, not a review-ready ticket", %{
      orchestrator: pid,
      watch_root: root
    } do
      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{
              "issue-46" => watch_entry("issue-46", "repo#46", state: "ci-wait", work_state: :paused)
            }
        }
      end)

      output = capture_io(fn -> AgentControlCLI.watch(mode: :full, roots: [root], log_roots: [root]) end)

      assert output =~ ~r/#46\s+ci-wait/
      assert output =~ "waiting for CI"
      refute output =~ "#46 ci-wait · needs review/merge"
    end
  end

  # Prewarm-enabled config for the CLI surface tests. No `base_build` and a
  # memory tracker keep RepoBase's own resolve/poll inert (no clone/build can
  # start) while `Config.prewarm_enabled?/0` reads true.
  defp with_prewarm_enabled do
    tmp = Aiur.TestSupport.tmp_root!("cli_prewarm")
    File.mkdir_p!(tmp)
    cfg = Path.join(tmp, "config")
    File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")
    previous = Application.get_env(:aiur, :workflow_file_path)
    Aiur.Workflow.set_workflow_file_path(cfg)

    on_exit(fn ->
      case previous do
        nil -> Aiur.Workflow.clear_workflow_file_path()
        path -> Aiur.Workflow.set_workflow_file_path(path)
      end
    end)

    :ok
  end

  # Drive the live RepoBase phase so `aiur status` renders the prewarm line
  # exactly as it would against a warming/errored base.
  defp with_repo_base_phase(phase) do
    pid = Process.whereis(Aiur.RepoBase) || flunk("RepoBase must be running for prewarm status tests")
    original = :sys.get_state(pid)

    :sys.replace_state(pid, fn state -> %{state | phase: phase, base_path: "/tmp/base"} end)

    on_exit(fn -> restore_repo_base(pid, original) end)

    :ok
  end

  defp restore_repo_base(pid, original) do
    if Process.alive?(pid), do: :sys.replace_state(pid, fn _state -> original end)
  end
end
