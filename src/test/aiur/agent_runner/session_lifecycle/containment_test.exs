defmodule Aiur.AgentRunner.SessionLifecycle.ContainmentTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Issue
  alias Aiur.TrackerIdentity
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  describe "authoritative no-provider startup failures" do
    test "reports a pre-handshake port exit to telemetry and the retry owner" do
      issue = %Issue{id: "2895", identifier: "2895", selected_backend: "codex"}
      previous = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

      Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn _kind, attributes, _opts ->
        send(self(), {:lifecycle, attributes})
      end)

      on_exit(fn ->
        if previous, do: Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, previous), else: Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder)
      end)

      opts = [
        telemetry_attempt_id: "2895:test",
        session_start_fun: fn _workspace, _opts -> {:error, {:port_exit, 23}} end
      ]

      assert {:error, {:port_exit, 23}} = SessionLifecycle.run_session("/workspaces/2895", issue, self(), opts, nil)

      assert_received {:lifecycle, %{event: "agent_spinup", boundary: "end", attempt_id: "2895:test", reason_class: "port_exit", exit_status: 23}}
      assert_received {:codex_worker_update, "2895", %{event: :startup_failed, reason: {:port_exit, 23}, timestamp: %DateTime{}}}
    end

    test "persists local boot proof before invoking a provider start" do
      ticket = "provider-boot-before-spawn-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: ticket, selected_backend: "codex", tracker_identity: telemetry_identity()}
      assert {:ok, lease} = Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry, host_boot_id_fun: fn -> {:ok, "boot-before"} end)
      assert {:ok, active_lease} = Ownership.activate(lease)
      parent = self()

      start_fun = fn _workspace, _opts ->
        send(parent, {:receipt_before_start, Store.get(ticket)})
        {:error, :bash_not_found}
      end

      assert {:error, :bash_not_found} =
               SessionLifecycle.run_session(
                 "/workspaces/#{ticket}",
                 issue,
                 nil,
                 [workspace_ownership: active_lease, session_start_fun: start_fun, telemetry_attempt_id: "attempt-test"],
                 nil
               )

      assert_received {:receipt_before_start, {:ok, %{provider_expected?: true, provider_scope: :local, provider_boot_id: "boot-before"}}}

      assert {:ok, %{phase: :released}} = Ownership.release_and_wait(active_lease)
    end

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
        issue = %Issue{identifier: ticket, selected_backend: backend, tracker_identity: telemetry_identity()}
        assert {:ok, lease} = Ownership.claim(ticket)
        assert {:ok, active_lease} = Ownership.activate(lease)

        start_fun = fn _workspace, _opts -> {:error, reason} end

        assert {:error, ^reason} =
                 SessionLifecycle.run_session(
                   "/workspaces/#{ticket}",
                   issue,
                   nil,
                   [workspace_ownership: active_lease, session_start_fun: start_fun, telemetry_attempt_id: "attempt-test"],
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

    test "releases the provider expectation when telemetry rejects before spawn" do
      ticket = "telemetry-pre-spawn-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: ticket, selected_backend: "claude"}
      assert {:ok, lease} = Ownership.claim(ticket)
      assert {:ok, active_lease} = Ownership.activate(lease)

      assert {:error, :missing_tracker_identity} =
               SessionLifecycle.run_session(
                 "/workspaces/#{ticket}",
                 issue,
                 nil,
                 [
                   workspace_ownership: active_lease,
                   telemetry_attempt_id: "attempt-test",
                   session_start_fun: fn _workspace, _opts -> flunk("telemetry rejection must precede process spawn") end
                 ],
                 nil
               )

      assert {:ok, %{phase: :released}} = Ownership.release_and_wait(active_lease)
      assert :none = Ownership.current(ticket)
    end

    test "failed REPL cleanup retains a late child during explicit release" do
      ticket = "failed-repl-cleanup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: ticket, selected_backend: "claude-repl", tracker_identity: telemetry_identity()}
      root_pid = System.unique_integer([:positive])
      late_child_pid = System.unique_integer([:positive])
      {:ok, alive} = Agent.start_link(fn -> %{root_pid => false, late_child_pid => true} end)

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(alive)
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
                 [workspace_ownership: active_lease, session_start_fun: start_fun, telemetry_attempt_id: "attempt-test"],
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
        Aiur.TestSupport.safe_stop(alive)
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

    test "plain cleanup success retains an unproven no-group provider" do
      ticket = "unproven-session-cleanup-#{System.unique_integer([:positive])}"
      root_pid = System.unique_integer([:positive])
      recorded_child_pid = System.unique_integer([:positive])
      late_child_pid = System.unique_integer([:positive])
      parent = self()

      {:ok, alive} =
        Agent.start_link(fn ->
          %{root_pid => false, recorded_child_pid => true, late_child_pid => true}
        end)

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(alive)
      end)

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 process_alive_fun: fn pid -> Agent.get(alive, &Map.fetch!(&1, pid)) end,
                 process_identity_fun: fn pid -> {:ok, {:test_process, pid}} end,
                 process_reap_fun: fn pid ->
                   send(parent, {:unproven_cleanup_reap, pid})
                   Agent.update(alive, &Map.put(&1, pid, false))
                 end
               )

      assert :ok =
               Ownership.track_provider(lease, %{
                 root_pid: root_pid,
                 descendant_pids: [root_pid, recorded_child_pid]
               })

      assert :ok =
               SessionLifecycle.stop_session_with_ownership(
                 %{backend: "claude-repl"},
                 lease,
                 fn _session -> :ok end
               )

      release = Task.async(fn -> Ownership.release_and_wait(lease) end)

      assert_receive {:unproven_cleanup_reap, ^recorded_child_pid}, 2_000
      assert_eventually(fn -> match?({:ok, %{phase: :reaping}}, Ownership.current(ticket)) end)
      refute Task.yield(release, 50)
      assert {:ok, %{provider_cleanup: :failed}} = Store.get(ticket)
      refute Agent.get(alive, &Map.fetch!(&1, recorded_child_pid))
      assert Agent.get(alive, &Map.fetch!(&1, late_child_pid))
      Task.shutdown(release, :brutal_kill)
    end

    test "cleanup exceptions fail closed before they are reraised" do
      ticket = "raised-session-cleanup-#{System.unique_integer([:positive])}"
      assert {:ok, lease} = Ownership.claim(ticket)

      assert_raise RuntimeError, "cleanup crashed", fn ->
        SessionLifecycle.stop_session_with_ownership(
          %{backend: "claude-repl"},
          lease,
          fn _session -> raise "cleanup crashed" end
        )
      end

      assert {:ok, %{provider_cleanup: :failed}} = Store.get(ticket)

      assert :ok = Ownership.mark_provider_cleanup_succeeded(lease)
      assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
    end

    test "a malformed session still fails loudly through the teardown catch-all" do
      # `stop_session_with_ownership/3` wraps the stop in `catch kind, reason`.
      # It reraises today, so the malformed-backend refusal survives teardown —
      # but nothing pinned that, and narrowing the catch-all to swallow would
      # turn the loud failure back into a silent one on the cleanup path.
      # Deliberately drives the real `CodingAgent.stop_session/1` default rather
      # than an injected stop_fun, and takes no workspace lease, so the guard is
      # proven end to end without the ownership registry.
      for session <- [%{thread_id: "teardown-no-backend"}, %{backend: :claude, thread_id: "teardown-atom"}] do
        error =
          assert_raise ArgumentError, fn ->
            SessionLifecycle.stop_session_with_ownership(session, nil)
          end

        assert error.message =~ inspect(session)
        assert error.message =~ "expected a binary :backend"
      end
    end

    test "authoritative cleanup success overrides a transient identity probe" do
      ticket = "successful-session-cleanup-unknown-#{System.unique_integer([:positive])}"
      process_group_id = System.unique_integer([:positive])

      assert {:ok, lease} =
               Ownership.claim(ticket, Aiur.Workspace.Ownership.Registry,
                 group_alive_fun: fn ^process_group_id -> true end,
                 process_identity_fun: fn ^process_group_id -> :unknown end
               )

      assert :ok = Ownership.track_process_group(lease, process_group_id)

      assert :ok =
               SessionLifecycle.stop_session_with_ownership(
                 %{backend: "claude-repl"},
                 lease,
                 fn _session -> {:ok, :cleanup_proven} end
               )

      assert :ok =
               SessionLifecycle.stop_session_with_ownership(
                 %{backend: "claude-repl"},
                 lease,
                 fn _session -> :ok end
               )

      assert {:ok, %{provider_cleanup: :succeeded}} = Store.get(ticket)

      assert {:ok, %{phase: :released}} = Ownership.release_and_wait(lease)
      assert :none = Ownership.current(ticket)
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

  defp telemetry_identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDOTelemetry",
      identifier: "1123",
      reason: nil
    }
  end
end
