defmodule Aiur.AgentRunner.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Workspace.Ownership

  describe "remote_session_backend/2" do
    test "maps remote-control claude to claude-repl and passes other cases through" do
      assert SessionLifecycle.remote_session_backend("claude", true) == "claude-repl"
      assert SessionLifecycle.remote_session_backend("claude", false) == "claude"
      assert SessionLifecycle.remote_session_backend("codex", true) == "codex"
    end
  end

  describe "should_display_tail?/3" do
    test "is true only for RC claude-repl sessions with an identifier" do
      assert SessionLifecycle.should_display_tail?("claude-repl", true, "101")

      refute SessionLifecycle.should_display_tail?("claude", true, "101")
      refute SessionLifecycle.should_display_tail?("codex", true, "101")
      refute SessionLifecycle.should_display_tail?("claude-repl", false, "101")
      refute SessionLifecycle.should_display_tail?("claude-repl", true, nil)
    end
  end

  describe "rc_session_name/2" do
    test "builds, scrubs, and clamps the remote-control name" do
      issue = %Issue{identifier: "7", id: "gid-7", title: "a\t'b'\n  `c` " <> String.duplicate("x", 100)}

      name = SessionLifecycle.rc_session_name(issue, "its-everdred/aiur")

      assert String.starts_with?(name, "Aiur: Aiur #7 - a b c")
      assert String.length(name) == 60
      refute name =~ ~r/[\t\n'`]/
    end

    test "omits the repo prefix when repo is nil" do
      issue = %Issue{identifier: "9", id: "gid-9", title: "No repo"}

      assert SessionLifecycle.rc_session_name(issue, nil) == "Aiur: #9 - No repo"
    end
  end

  describe "maybe_trust_remote_control_workspace/4" do
    test "trusts only local RC workspaces and swallows trust errors" do
      parent = self()
      trust_fun = fn ws -> send(parent, {:trusted, ws}) && :ok end

      assert :ok = SessionLifecycle.maybe_trust_remote_control_workspace("/ws/9", true, nil, trust_fun)
      assert_received {:trusted, "/ws/9"}

      assert :ok = SessionLifecycle.maybe_trust_remote_control_workspace("/ws/9", false, nil, fn _ -> flunk("must not run") end)
      assert :ok = SessionLifecycle.maybe_trust_remote_control_workspace("/ws/9", true, "box-2", fn _ -> flunk("must not run") end)
      assert :ok = SessionLifecycle.maybe_trust_remote_control_workspace("/ws/9", true, nil, fn _ -> {:error, :enoent} end)
    end
  end

  describe "start_agent_session/3" do
    test "tags the started backend and falls back from claude-repl to claude once" do
      parent = self()

      start_fun = fn _workspace, opts ->
        send(parent, {:attempt, Keyword.fetch!(opts, :backend), Keyword.get(opts, :remote_control)})

        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{handle: :headless}}
          other -> {:ok, %{backend_seen: other}}
        end
      end

      assert {:ok, %{backend: "codex", attempt_id: "attempt-codex"}} =
               SessionLifecycle.start_agent_session("/ws", [backend: "codex", model: nil, attempt_id: "attempt-codex"], start_fun)

      assert {:ok, %{backend: "claude", attempt_id: "attempt-claude"}} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: "opus", remote_control: true, attempt_id: "attempt-claude"],
                 start_fun
               )

      assert_received {:attempt, "claude-repl", true}
      assert_received {:attempt, "claude", nil}
    end

    test "non-repl start errors propagate unchanged" do
      start_fun = fn _workspace, _opts -> {:error, :boom} end

      assert {:error, :boom} = SessionLifecycle.start_agent_session("/ws", [backend: "claude", model: nil], start_fun)
    end
  end

  describe "authoritative no-provider startup failures" do
    test "preserves the legacy no-lease session API" do
      issue = %Issue{identifier: "legacy-no-lease", selected_backend: "codex"}
      start_fun = fn _workspace, _opts -> {:error, :bash_not_found} end

      assert {:error, :bash_not_found} =
               SessionLifecycle.run_session(
                 "/workspaces/legacy-no-lease",
                 issue,
                 nil,
                 [session_start_fun: start_fun],
                 nil
               )
    end

    test "cancel the exact expectation so the run can release and retry" do
      for {backend, reason} <- [
            {"codex", {:invalid_workspace_cwd, :workspace_root, "/workspaces"}},
            {"codex", {:invalid_workspace_cwd, :outside_workspace_root, "/outside", "/workspaces"}},
            {"codex", :bash_not_found},
            {"claude-repl", :no_tmux},
            {"claude-repl", :no_tmux_executable},
            {"claude-repl", :remote_control_requires_dashboard}
          ] do
        ticket = "no-provider-retry-#{System.unique_integer([:positive])}"
        issue = %Issue{identifier: ticket, selected_backend: backend}
        assert {:ok, lease} = Ownership.claim(ticket)
        assert {:ok, active_lease} = Ownership.activate(lease)

        start_fun = fn _workspace, _opts -> {:error, reason} end

        assert {:error, ^reason} =
                 SessionLifecycle.run_session(
                   "/workspaces/#{ticket}",
                   issue,
                   nil,
                   [workspace_ownership: active_lease, session_start_fun: start_fun],
                   nil
                 )

        assert {:ok, %{phase: :released}} = Ownership.release_and_wait(active_lease)
        assert :none = Ownership.current(ticket)

        assert {:ok, retry_lease} = Ownership.claim(ticket)
        assert :ok = Ownership.release(retry_lease)
      end
    end

    test "retains an uncertain startup until cleanup is explicitly proven" do
      ticket = "uncertain-provider-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: ticket, selected_backend: "codex"}
      assert {:ok, lease} = Ownership.claim(ticket)
      assert {:ok, active_lease} = Ownership.activate(lease)

      uncertain_error = {:provider_spawn_failed, :metadata_unavailable}
      start_fun = fn _workspace, _opts -> {:error, uncertain_error} end

      assert {:error, ^uncertain_error} =
               SessionLifecycle.run_session(
                 "/workspaces/#{ticket}",
                 issue,
                 nil,
                 [workspace_ownership: active_lease, session_start_fun: start_fun],
                 nil
               )

      release = Task.async(fn -> Ownership.release_and_wait(active_lease) end)

      assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
      refute Task.yield(release, 50)

      # This direct cleanup proof is deliberately test-only: an uncertain
      # production start must retain the lease rather than replace a live cwd.
      assert :ok = Ownership.cancel_provider_expectation(active_lease)
      assert :ok = Ownership.release(active_lease)
      assert {:ok, %{phase: :released}} = Task.await(release, 2_000)

      assert {:ok, retry_lease} = Ownership.claim(ticket)
      assert :ok = Ownership.release(retry_lease)
    end

    test "failed REPL cleanup retains a late child during explicit release" do
      ticket = "failed-repl-cleanup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: ticket, selected_backend: "claude-repl"}
      root_pid = System.unique_integer([:positive])
      late_child_pid = System.unique_integer([:positive])
      {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, late_child_pid => true} end)

      on_exit(fn ->
        if Process.alive?(alive), do: Agent.stop(alive)
      end)

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 process_alive_fun: fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end,
                 process_identity_fun: fn pid -> {:ok, {:test_process, pid}} end
               )

      assert {:ok, active_lease} = Ownership.activate(lease)

      start_fun = fn _workspace, opts ->
        # The readiness snapshot saw only the root; the child escaped before
        # failed pane cleanup returned to the owning runner.
        assert :ok = Keyword.fetch!(opts, :on_provider_started).(%{root_pid: root_pid, descendant_pids: [root_pid]})
        {:error, {:repl_cleanup_failed, :permission_denied}}
      end

      assert {:error, {:repl_cleanup_failed, :permission_denied}} =
               SessionLifecycle.run_session(
                 "/workspaces/#{ticket}",
                 issue,
                 nil,
                 [workspace_ownership: active_lease, session_start_fun: start_fun],
                 nil
               )

      release = Task.async(fn -> Ownership.release_and_wait(active_lease) end)

      assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
      refute Task.yield(release, 50)
      assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
      Task.shutdown(release, :brutal_kill)
    end

    test "failed graceful cleanup cannot downgrade an explicit no-group release" do
      ticket = "failed-session-cleanup-#{System.unique_integer([:positive])}"
      root_pid = System.unique_integer([:positive])
      late_child_pid = System.unique_integer([:positive])
      {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, late_child_pid => true} end)

      on_exit(fn ->
        if Process.alive?(alive), do: Agent.stop(alive)
      end)

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 process_alive_fun: fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end,
                 process_identity_fun: fn pid -> {:ok, {:test_process, pid}} end
               )

      assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [root_pid]})

      assert {:error, {:repl_cleanup_failed, :pane_still_alive}} =
               SessionLifecycle.stop_session_with_ownership(
                 %{backend: "claude-repl"},
                 lease,
                 fn _session -> {:error, {:repl_cleanup_failed, :pane_still_alive}} end
               )

      release = Task.async(fn -> Ownership.release_and_wait(lease) end)

      assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
      refute Task.yield(release, 50)
      assert {:error, {:workspace_owned, {:ok, %{phase: :reaping}}}} = Ownership.claim(ticket)
      Task.shutdown(release, :brutal_kill)
    end

    test "proven graceful cleanup preserves ordinary explicit release" do
      ticket = "successful-session-cleanup-#{System.unique_integer([:positive])}"
      root_pid = System.unique_integer([:positive])

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 process_alive_fun: fn ^root_pid -> false end,
                 process_identity_fun: fn ^root_pid -> :gone end
               )

      assert :ok = Ownership.track_provider(lease, %{root_pid: root_pid, descendant_pids: [root_pid]})

      assert :ok =
               SessionLifecycle.stop_session_with_ownership(
                 %{backend: "claude-repl"},
                 lease,
                 fn _session -> :ok end
               )

      assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
      assert :none = Ownership.current(ticket)
    end
  end

  describe "session accessors" do
    test "session_backend/1 defaults to configured agent kind" do
      assert SessionLifecycle.session_workspace(%{workspace: "/ws"}) == "/ws"
      assert SessionLifecycle.session_workspace(%{}) == nil
      assert SessionLifecycle.session_worker_host(%{worker_host: "box"}) == "box"
      assert SessionLifecycle.session_worker_host(%{}) == nil
      assert SessionLifecycle.session_backend(%{backend: "claude-repl"}) == "claude-repl"
      assert SessionLifecycle.session_backend(%{}) == Config.agent_kind()
    end
  end

  describe "workspace containment" do
    test "accepts every valid session shape when local process-group discovery is unavailable" do
      for {shape, session, worker_host} <- [
            {"headless Claude", %{backend: "claude", metadata: %{claude_app_server_pid: "424242"}}, nil},
            {"Claude REPL", %{backend: "claude-repl", os_pid: 424_242}, nil},
            {"remote Codex", %{backend: "codex", metadata: %{codex_app_server_pid: "424242"}}, "worker-a"},
            {"local Codex", %{backend: "codex", metadata: %{codex_app_server_pid: "424242"}}, nil}
          ] do
        ticket = "session-no-pgid-#{System.unique_integer([:positive])}"
        assert {:ok, lease} = Ownership.claim(ticket)
        assert {:ok, active_lease} = Ownership.activate(lease)

        assert :ok = SessionLifecycle.track_session_containment(active_lease, session, worker_host), shape
        assert :ok = Ownership.release(active_lease)
      end
    end

    test "allows legacy sessions with no workspace lease" do
      session = %{backend: "claude", metadata: %{claude_app_server_pid: "424242"}}

      assert :ok = SessionLifecycle.track_session_containment(nil, session, nil)
    end
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
