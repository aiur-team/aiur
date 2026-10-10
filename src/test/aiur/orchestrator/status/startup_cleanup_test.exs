defmodule Aiur.Orchestrator.Status.StartupCleanupTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.Orchestrator.WorkspaceCleanup
  alias Aiur.SessionHandle
  alias Aiur.Workspace.Ownership

  defmodule StartupCleanupLinearClient do
    def fetch_candidate_issues, do: {:ok, []}

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(_states, opts) do
      notify({:startup_cleanup_fetch_issues_by_states, opts})
      {:error, {:linear_api_status, 401}}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def graphql(query, %{"issueId" => _issue_id, "stateName" => "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{issueId: _issue_id, stateName: "rework"})
        when is_binary(query) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"states" => %{"nodes" => [%{"id" => "state-rework"}]}}
           }
         }
       }}
    end

    def graphql(query, %{"issueId" => _issue_id, "stateId" => "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    def graphql(query, %{issueId: _issue_id, stateId: "state-rework"})
        when is_binary(query) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    end

    defp notify(message) do
      case Application.get_env(:aiur, :startup_cleanup_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule StartupCleanupGitHubClient do
    def preflight_auth, do: :ok
    def fetch_candidate_issues, do: {:ok, Application.get_env(:aiur, :startup_cleanup_issues, [])}

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(states, opts) do
      notify({:github_startup_cleanup_fetch_issues_by_states, states, opts})
      {:ok, Application.get_env(:aiur, :startup_cleanup_issues, [])}
    end

    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}
    def hydrate_blocked_by(issue), do: {:ok, issue}

    defp notify(message) do
      case Application.get_env(:aiur, :startup_cleanup_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  test "startup terminal cleanup skips Linear fetch when Linear token is missing" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: nil,
        tracker_project_slug: "project",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
        end)

      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
      assert log =~ "Skipping startup terminal workspace cleanup: :missing_linear_api_token"
      # A blanket `refute log =~ "[warning]"/"[error]"` would pollute on an
      # unrelated concurrent test's warning: `capture_log` captures the whole
      # BEAM's log stream, not just this process's (the #594 flake class). But
      # the positive assertion above matches regardless of level, so it alone
      # doesn't prove this path stays at debug — scope the refute to this
      # path's own message instead of the whole captured stream.
      refute log =~ ~r/\[(warning|error)\].*Skipping startup terminal workspace cleanup/
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "startup terminal cleanup preserves full config preflight after Linear auth is present" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        agent_kind: "bogus",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
        end)

      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
      assert log =~ "Skipping startup terminal workspace cleanup: {:unsupported_agent_kind, \"bogus\"}"
      assert log =~ "[warning]"
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "startup terminal cleanup suppresses Linear auth failure logs" do
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "invalid-token",
        tracker_project_slug: "project",
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      log =
        capture_log([level: :debug], fn ->
          assert %Orchestrator.State{} =
                   WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})
        end)

      assert_received {:startup_cleanup_fetch_issues_by_states, opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      assert log =~ "Skipping startup terminal workspace cleanup; failed to fetch terminal issues: {:linear_api_status, 401}"
      # No global `refute log =~ "[warning]"/"[error]"` here: `capture_log`
      # captures the whole BEAM's log stream, so an unrelated concurrent test
      # emitting a warning/error pollutes this assertion (the #594 flake class).
      # The positive assertion above already proves the auth failure is demoted
      # to debug.
    after
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
    end
  end

  test "GitHub startup terminal cleanup does not depend on Linear auth" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_linear_client = Application.get_env(:aiur, :linear_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_terminal_states: ["done"],
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :linear_client_module, StartupCleanupLinearClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["done"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      refute_received {:startup_cleanup_fetch_issues_by_states, _opts}
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:linear_client_module, previous_linear_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end
  end

  test "startup terminal cleanup clears persisted session handles" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_issues = Application.get_env(:aiur, :startup_cleanup_issues)
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_log_file = Application.get_env(:aiur, :log_file)
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-startup-terminal-cleanup")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")
      Application.put_env(:aiur, :log_file, Path.join([workspace_root, "log", "agent.md"]))

      terminal_workspace = Path.join([workspace_root, "owner", "repo", "610"])
      File.mkdir_p!(terminal_workspace)
      File.write!(Path.join(terminal_workspace, "dirty.txt"), "leftover")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        workspace_root: workspace_root,
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      Application.put_env(:aiur, :startup_cleanup_issues, [
        %Issue{id: "issue-610", identifier: "610", title: "Done", state: "done"}
      ])

      :ok = SessionHandle.save("610", %{backend: "codex", thread_id: "thread-clear"})

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_terminal_workspace_cleanup(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["done"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      # The sweep saves and deletes in one task, off the Orchestrator (#2743).
      assert_receive {:workspace_cleanup_finished, "610", :ok}, 10_000
      refute File.exists?(terminal_workspace)
      assert :none == SessionHandle.load("610", "codex")
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_application_env(:startup_cleanup_issues, previous_issues)
      restore_application_env(:log_file, previous_log_file)
      restore_env("GITHUB_TOKEN", previous_github_token)
      File.rm_rf(workspace_root)
    end
  end

  test "startup todo cleanup removes stale todo workspaces before dispatch" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_issues = Application.get_env(:aiur, :startup_cleanup_issues)
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_log_file = Application.get_env(:aiur, :log_file)
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-startup-todo-cleanup")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")
      Application.put_env(:aiur, :log_file, Path.join([workspace_root, "log", "agent.md"]))

      todo_workspace = Path.join([workspace_root, "owner", "repo", "586"])
      in_progress_workspace = Path.join([workspace_root, "owner", "repo", "587"])
      leased_todo_identifier = "leased-todo-#{System.unique_integer([:positive])}"
      leased_todo_workspace = Path.join([workspace_root, "owner", "repo", leased_todo_identifier])
      File.mkdir_p!(todo_workspace)
      File.mkdir_p!(in_progress_workspace)
      File.mkdir_p!(leased_todo_workspace)
      File.write!(Path.join(leased_todo_workspace, "dirty.txt"), "leased")
      File.write!(Path.join(todo_workspace, "dirty.txt"), "leftover")
      File.write!(Path.join(in_progress_workspace, "dirty.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        workspace_root: workspace_root,
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      Application.put_env(:aiur, :startup_cleanup_issues, [
        %Issue{id: "issue-586", identifier: "586", title: "Todo", state: "todo"},
        %Issue{id: "issue-587", identifier: "587", title: "Live", state: "in-progress"},
        %Issue{id: "issue-leased", identifier: leased_todo_identifier, title: "Leased", state: "todo"}
      ])

      # A lease still held on a todo ticket (a stopped runner mid-reap) owns
      # its checkout, so startup cleanup must leave that workspace alone.
      parent = self()

      lease_owner =
        spawn(fn ->
          send(parent, {:leased, Ownership.claim(leased_todo_identifier)})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, _lease}}, 5_000

      # `todo` is NOT a terminal state, so this startup cleanup must remove the
      # stale workspace WITHOUT clearing the resume handle — a re-dispatched todo
      # issue should still be able to rejoin its prior thread now that
      # `claude-repl` is resumable (#613). The terminal-cleanup path is what
      # clears the handle (see the terminal-cleanup test above).
      :ok = SessionHandle.save("586", %{backend: "claude-repl", thread_id: "thread-keep"})

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_startup_todo_workspace_cleanup(%Orchestrator.State{})

      assert_received {:github_startup_cleanup_fetch_issues_by_states, ["todo"], opts}
      assert Keyword.fetch!(opts, :quiet_auth_errors?) == true
      refute File.exists?(todo_workspace)
      assert File.exists?(in_progress_workspace)
      assert File.read!(Path.join(in_progress_workspace, "dirty.txt")) == "keep"
      assert File.read!(Path.join(leased_todo_workspace, "dirty.txt")) == "leased"
      Process.exit(lease_owner, :kill)
      # Non-terminal cleanup leaves the resume handle intact.
      assert {:ok, %{thread_id: "thread-keep"}} = SessionHandle.load("586", "claude-repl")
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_application_env(:startup_cleanup_issues, previous_issues)
      restore_application_env(:log_file, previous_log_file)
      restore_env("GITHUB_TOKEN", previous_github_token)
      File.rm_rf(workspace_root)
    end
  end

  test "test ticket scope protects unrelated dirty todo workspace before startup cleanup and candidate polling" do
    previous_github_client = Application.get_env(:aiur, :github_client_module)
    previous_test_pid = Application.get_env(:aiur, :startup_cleanup_test_pid)
    previous_issues = Application.get_env(:aiur, :startup_cleanup_issues)
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_scope = System.get_env("AIUR_DEV_TEST_TICKET_IDS")
    previous_log_file = Application.get_env(:aiur, :log_file)
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-scoped-startup-cleanup")

    try do
      System.put_env("GITHUB_TOKEN", "gh-test-token")
      System.put_env("AIUR_DEV_TEST_TICKET_IDS", "99")
      Application.put_env(:aiur, :log_file, Path.join([workspace_root, "log", "agent.md"]))

      pinned_workspace = Path.join([workspace_root, "owner", "repo", "99"])
      unrelated_workspace = Path.join([workspace_root, "owner", "repo", "2413"])
      File.mkdir_p!(pinned_workspace)
      File.mkdir_p!(unrelated_workspace)
      File.write!(Path.join(pinned_workspace, "old.txt"), "sandbox reset candidate")
      File.write!(Path.join(unrelated_workspace, "dirty.txt"), "uncommitted bytes must survive\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress"],
        tracker_terminal_states: ["done"],
        workspace_root: workspace_root,
        poll_interval_seconds: 60
      )

      Application.put_env(:aiur, :github_client_module, StartupCleanupGitHubClient)
      Application.put_env(:aiur, :startup_cleanup_test_pid, self())

      Application.put_env(:aiur, :startup_cleanup_issues, [
        %Issue{id: "issue-99", identifier: "99", title: "Pinned", state: "todo"},
        %Issue{id: "issue-2413", identifier: "2413", title: "Unrelated", state: "todo"}
      ])

      assert %Orchestrator.State{} =
               WorkspaceCleanup.run_startup_todo_workspace_cleanup(%Orchestrator.State{})

      refute File.exists?(pinned_workspace)
      assert File.read!(Path.join(unrelated_workspace, "dirty.txt")) == "uncommitted bytes must survive\n"
      assert :ok = WorkspaceCleanup.cleanup_issue_workspace("2413")
      assert File.read!(Path.join(unrelated_workspace, "dirty.txt")) == "uncommitted bytes must survive\n"
      assert {:ok, [%Issue{identifier: "99"}]} = Tracker.fetch_candidate_issues()
      assert {:ok, [%Issue{identifier: "99"}], %{}} = Aiur.GitHub.Tracker.fetch_candidate_issues_conditional(%{})
      assert {:ok, [%Issue{identifier: "99"}]} = Tracker.fetch_issues_by_states(["todo"])
    after
      restore_application_env(:github_client_module, previous_github_client)
      restore_application_env(:startup_cleanup_test_pid, previous_test_pid)
      restore_application_env(:startup_cleanup_issues, previous_issues)
      restore_application_env(:log_file, previous_log_file)
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("AIUR_DEV_TEST_TICKET_IDS", previous_scope)
      File.rm_rf(workspace_root)
    end
  end
end
