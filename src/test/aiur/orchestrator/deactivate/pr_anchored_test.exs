defmodule Aiur.Orchestrator.Deactivate.PrAnchoredTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.PrAnchored
  alias Aiur.SessionHandle

  import Aiur.OrchestratorDeactivateSupport

  describe "PR-anchored comment routing (U4)" do
    setup do
      test_root = Aiur.TestSupport.tmp_root!("aiur-pr-anchored-route")

      File.mkdir_p!(test_root)
      on_exit(fn -> File.rm_rf(test_root) end)
      {:ok, test_root: test_root}
    end

    test "routes an open human PR (non-aiur head) PR-anchored, with NO agent:* label flip", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # A PR fetch returning an OPEN PR on a human branch. The capture fun
      # records the synthetic unit instead of spawning a real agent.
      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn 77 ->
          {:ok, %{"number" => 77, "state" => "open", "title" => "Add login", "body" => "please review", "head" => %{"ref" => "feature/login"}}}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      receive_barrier({:pr_anchored_dispatched, %Issue{} = unit})

      # Identity: keyed by PR number (resume key + comment topic), NOT a tracker id.
      assert unit.identifier == "77"
      assert unit.id == "pr-77"
      assert unit.pr_head_ref == "feature/login"
      assert unit.branch_name == "feature/login"
      assert unit.title == "Add login"

      # Safety: a synthetic PR unit carries no agent:* label — the human PR is
      # never mutated.
      assert unit.labels == []
      refute Enum.any?(unit.labels, &String.starts_with?(&1, "agent:"))
    end

    test "an UNTRUSTED commenter on an open human PR is refused PR-anchored dispatch", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()
      fetcher_calls = capture_fetcher(test_pid)

      # Same open-human-PR setup as the happy path, but the comment author is NOT
      # trusted. Third-party comments must never wake a PR-anchored agent (the
      # agent treats the comment body as instructions and can push to the branch).
      # The trust gate short-circuits at routing time: no PR-anchored dispatch and
      # not even a `GET /pulls/N` fetch — the comment falls through to legacy.
      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: false,
        open_pull_request_fetcher:
          fetcher_calls.(fn 77 ->
            {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
          end),
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received {:pr_anchored_dispatched, _unit}
      refute_received {:fetcher_called, _pr_number}
    end

    test "a 404 (plain issue) falls through to the legacy path, never PR-anchored", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()
      fetcher_calls = capture_fetcher(test_pid)

      # `/pulls/N` 404 → {:ok, nil}: N is a plain tracker issue. Trusted author so
      # routing reaches the fetch; the nil result then falls through to legacy.
      event = %{
        topic: "ticket.55.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fetcher_calls.(fn 55 -> {:ok, nil} end),
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      receive_barrier({:fetcher_called, 55})
      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "an aiur/<N>-headed PR (legacy aiur PR) falls through to the legacy path", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # An OPEN PR whose head is aiur/<N> is a LEGACY aiur PR; its comments must
      # keep flowing through the unchanged reactivation, never PR-anchored.
      event = %{
        topic: "ticket.42.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn 42 ->
          {:ok, %{"number" => 42, "state" => "open", "head" => %{"ref" => "aiur/42"}}}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "feature off bypasses routing entirely — no /pulls/N fetch", %{test_root: test_root} do
      # pr_watch disabled (default): the legacy path runs and the PR fetcher is
      # NEVER called (zero new GitHub requests).
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "acme/widgets",
        workspace_root: test_root
      )

      test_pid = self()

      event = %{
        topic: "ticket.99.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn _n ->
          send(test_pid, :fetcher_called)
          {:ok, nil}
        end,
        pr_anchored_dispatch_fun: fn state, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          state
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, empty_orchestrator_state())

      refute_received :fetcher_called
      refute_received {:pr_anchored_dispatched, _unit}
    end

    test "a follow-up comment on a running PR-anchored agent resumes (no re-dispatch)", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)
      test_pid = self()

      # A PR-anchored agent is already running, keyed by identifier == "77".
      state =
        empty_orchestrator_state()
        |> Map.put(:running, %{
          "pr-77" => %{
            pid: nil,
            ref: nil,
            identifier: "77",
            issue: %Issue{id: "pr-77", identifier: "77", state: "pr-watch", pr_head_ref: "feature/login"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        })

      event = %{
        topic: "ticket.77.pr.review_comment",
        author_trusted?: true,
        open_pull_request_fetcher: fn _n ->
          send(test_pid, :fetcher_called)
          {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
        end,
        pr_anchored_dispatch_fun: fn s, issue ->
          send(test_pid, {:pr_anchored_dispatched, issue})
          s
        end
      }

      {:noreply, _next} = Orchestrator.handle_info({:event, event}, state)

      # Resolved to the EXISTING running entry: no fresh PR resolution, no
      # re-dispatch (the live agent sees the comment via its own subscription).
      refute_received :fetcher_called
      refute_received {:pr_anchored_dispatched, _unit}
    end
  end

  describe "PR-anchored lifecycle teardown (U6)" do
    setup do
      test_root = Aiur.TestSupport.tmp_root!("aiur-pr-anchored-teardown")

      File.mkdir_p!(test_root)
      on_exit(fn -> File.rm_rf(test_root) end)
      {:ok, test_root: test_root}
    end

    test "a PR-anchored agent whose PR closed/merged is terminated and its pr-<pr#> workspace cleaned",
         %{test_root: test_root} do
      enable_pr_watch!(test_root)

      # The PR-anchored workspace lives at the `pr-<pr#>` leaf (namespaced by
      # repo), NOT the bare `<pr#>` leaf. Create it so we can prove teardown
      # removes the correct directory.
      pr_workspace = Path.join([test_root, "acme", "widgets", "pr-77"])
      File.mkdir_p!(pr_workspace)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(agent_pid)

      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          # {:ok, nil} == closed/merged/missing PR.
          open_pull_request_fetcher: fn "77" -> {:ok, nil} end
        )

      # Running entry, claim, and retry_attempts all torn down.
      refute Map.has_key?(next.running, "pr-77")
      refute MapSet.member?(next.claimed, "pr-77")
      refute Map.has_key?(next.retry_attempts, "pr-77")

      # Agent task was killed.
      receive do
        {:DOWN, ^ref, :process, ^agent_pid, :killed} -> :ok
      end

      # The pr-<pr#> workspace is gone — no orphan left behind. The save and
      # delete run in a task (#2743).
      assert_receive {:workspace_cleanup_finished, "pr-77", :ok}, 10_000
      refute File.exists?(pr_workspace)
    end

    test "a PR-anchored agent whose PR closed clears its persisted resume handle",
         %{test_root: test_root} do
      enable_pr_watch!(test_root)

      # claude-repl is resumable (#613): without clearing on a closed PR, a
      # reopened PR would `--resume` the finished thread. The handle is keyed by
      # the PR-number identifier the agent session persisted under (here "77"),
      # not the `pr-77` running-map key.
      :ok = SessionHandle.save("77", %{backend: "claude-repl", thread_id: "session-xyz"})
      assert {:ok, %{thread_id: "session-xyz"}} = SessionHandle.load("77", "claude-repl")

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
        # {:ok, nil} == closed/merged/missing PR.
        open_pull_request_fetcher: fn "77" -> {:ok, nil} end
      )

      # The closed-PR teardown is terminal for this unit, so the handle is gone.
      assert :none == SessionHandle.load("77", "claude-repl")
    end

    test "a PR-anchored agent whose PR is still open is NOT terminated", %{test_root: test_root} do
      enable_pr_watch!(test_root)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn "77" ->
            {:ok, %{"number" => 77, "state" => "open", "head" => %{"ref" => "feature/login"}}}
          end
        )

      assert Map.has_key?(next.running, "pr-77")
      assert MapSet.member?(next.claimed, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "a fetch error does NOT terminate (transient-safe)", %{test_root: test_root} do
      enable_pr_watch!(test_root)

      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn "77" -> {:error, :rate_limited} end
        )

      assert Map.has_key?(next.running, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "feature off issues no fetch and terminates nothing", %{test_root: test_root} do
      # pr_watch disabled (default): no fetch, no teardown.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "acme/widgets",
        workspace_root: test_root
      )

      test_pid = self()
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      state = pr_anchored_running_state(77, agent_pid)

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn _pr ->
            send(test_pid, :fetcher_called)
            {:ok, nil}
          end
        )

      refute_received :fetcher_called
      assert Map.has_key?(next.running, "pr-77")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end

    test "no PR-anchored running entries issues no fetch (legacy entries are skipped)", %{
      test_root: test_root
    } do
      enable_pr_watch!(test_root)

      test_pid = self()
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)

      # A legacy tracker-issue running entry (state != @pr_anchored_state) must
      # never be selected for PR-anchored teardown — and with zero PR-anchored
      # entries, no fetch is issued at all.
      state = %Orchestrator.State{
        running: %{
          "issue-1" => %{
            pid: agent_pid,
            ref: nil,
            identifier: "501",
            issue: %Issue{id: "issue-1", identifier: "501", state: "in-progress"},
            started_at: DateTime.utc_now(),
            control: %{status: :working}
          }
        },
        claimed: MapSet.new(["issue-1"]),
        retry_attempts: %{}
      }

      next =
        PrAnchored.maybe_stop_closed_pr_anchored_agents(state,
          open_pull_request_fetcher: fn _pr ->
            send(test_pid, :fetcher_called)
            {:ok, nil}
          end
        )

      refute_received :fetcher_called
      assert Map.has_key?(next.running, "issue-1")
      assert Process.alive?(agent_pid)

      Process.exit(agent_pid, :kill)
    end
  end
end
