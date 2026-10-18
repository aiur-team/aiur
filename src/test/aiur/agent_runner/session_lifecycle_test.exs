defmodule Aiur.AgentRunner.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.Accounts.UsageReadings
  alias Aiur.AgentRunner
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Workspace.Ownership

  describe "remote_session_backend/2" do
    test "maps remote-control claude to claude-repl and passes other cases through" do
      assert SessionLifecycle.remote_session_backend("claude", true) == "claude-repl"
      assert SessionLifecycle.remote_session_backend("claude", false) == "claude"
      assert SessionLifecycle.remote_session_backend("codex", true) == "codex"
    end

    test "reports the transport backend selected for a remote-control session" do
      issue = %Issue{
        id: "issue-rc-execution",
        identifier: "RC-EXECUTION",
        selected_backend: "claude",
        labels: ["model:claude-opus", "model:remote"]
      }

      {"claude-repl", true, session_opts} =
        SessionLifecycle.resolve_session_options(issue, [], nil)

      assert {:ok, session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 session_opts,
                 fn _workspace, opts ->
                   {:ok, %{thread_id: "thread-rc", model: Keyword.get(opts, :model)}}
                 end
               )

      assert :ok = SessionLifecycle.report_session_execution(self(), issue, session)

      assert_receive {:session_execution_info, "issue-rc-execution", %{backend: "claude-repl", requested_model: "opus", effort: nil}}, 1000
    end
  end

  describe "model resolution in resolve_session_options/3" do
    test "a generic codex tag reaches the backend as the newest version in that family" do
      issue = %Issue{id: "issue-alias", identifier: "ALIAS", selected_backend: "codex", labels: ["model:codex-sol"]}

      {"codex", false, session_opts} = SessionLifecycle.resolve_session_options(issue, [], nil)

      model = Keyword.fetch!(session_opts, :model)
      refute model == "sol"
      assert model == Aiur.CodingAgent.resolve_model("codex", "sol")
    end

    test "an explicitly pinned codex tag still pins that exact version" do
      issue = %Issue{id: "issue-pin", identifier: "PIN", selected_backend: "codex", labels: ["model:codex-gpt-5.4"]}

      {"codex", false, session_opts} = SessionLifecycle.resolve_session_options(issue, [], nil)

      assert Keyword.fetch!(session_opts, :model) == "gpt-5.4"
    end

    test "a claude alias is handed over untouched so the claude CLI resolves it" do
      issue = %Issue{id: "issue-native", identifier: "NATIVE", selected_backend: "claude", labels: ["model:claude-opus"]}

      {"claude", false, session_opts} = SessionLifecycle.resolve_session_options(issue, [], nil)

      assert Keyword.fetch!(session_opts, :model) == "opus"
    end

    test "a model aiur doesn't know is passed through, never swapped for a different one" do
      # Silently substituting the backend default would hide a retired pin and
      # run work on a model nobody asked for.
      issue = %Issue{id: "issue-unknown", identifier: "UNKNOWN", selected_backend: "codex", labels: ["model:codex-gpt-9.9-nova"]}

      {"codex", false, session_opts} = SessionLifecycle.resolve_session_options(issue, [], nil)

      assert Keyword.fetch!(session_opts, :model) == "gpt-9.9-nova"
    end
  end

  describe "Claude account selection wait" do
    test "waits until the earliest exhausted account reset when no account is available" do
      reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.truncate(:second)
      UsageReadings.reset()

      on_exit(fn -> UsageReadings.reset() end)

      :ok =
        UsageReadings.record(
          "claude",
          "default",
          {:ok,
           %{
             windows: [
               %{window: "seven_day", used_percent: 100, resets_at: reset_at},
               %{window: "five_hour", used_percent: 100, resets_at: DateTime.add(reset_at, 600, :second)}
             ]
           }},
          DateTime.utc_now()
        )

      issue = %Issue{id: "issue-account-wait", identifier: "ACCOUNT-WAIT", selected_backend: "claude"}

      config = %{
        accounts: %{"claude" => ["default"]},
        account_selection: "balance"
      }

      {"claude", false, session_opts} =
        SessionLifecycle.resolve_session_options(
          issue,
          [account_config: config, account_list_fun: fn "claude" -> [%{name: "default"}] end],
          nil
        )

      assert Keyword.get(session_opts, :account_selection_wait) == DateTime.to_iso8601(reset_at)
      refute Keyword.has_key?(session_opts, :account_selection_error)

      issue = %Issue{id: "issue-account-wait", identifier: "ACCOUNT-WAIT"}
      parent = self()
      runner = spawn(fn -> send(parent, {:wait_result, AgentRunner.pause_for_account_usage_wait(issue, parent, DateTime.to_iso8601(reset_at))}) end)

      assert_receive {:worker_control_state, "issue-account-wait", :paused, pause_payload}, 1_000
      assert pause_payload.kind == :usage_limit_exhausted
      assert pause_payload.reset_at == DateTime.to_iso8601(reset_at)

      send(runner, {:resume_agent, 1})
      assert_receive {:wait_result, :resume_after_before_run_pause}, 1_000
    end
  end

  describe "maybe_alert_unsupported_model/5" do
    test "an unknown model warns with both remediations named" do
      issue = %Issue{id: "issue-unsupported", identifier: "UNSUPPORTED"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = SessionLifecycle.maybe_alert_unsupported_model(issue, "/ws", nil, "codex", "gpt-9.9-nova")
        end)

      assert log =~ "gpt-9.9-nova"
      # The operator has to be able to act on this without reading the source:
      # a new model is learned from the CLI's list, a retired pin must move.
      assert log =~ "model list"
      assert log =~ "agent.routing"
      assert log =~ "passed to the backend"
    end

    test "a known model and an unpinned model stay silent" do
      issue = %Issue{id: "issue-known", identifier: "KNOWN"}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert :ok = SessionLifecycle.maybe_alert_unsupported_model(issue, "/ws", nil, "codex", "sol")
               assert :ok = SessionLifecycle.maybe_alert_unsupported_model(issue, "/ws", nil, "codex", "gpt-5.4")
               assert :ok = SessionLifecycle.maybe_alert_unsupported_model(issue, "/ws", nil, "codex", nil)
             end) == ""
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

  describe "session accessors" do
    test "session accessors read what the session carries" do
      assert SessionLifecycle.session_workspace(%{workspace: "/ws"}) == "/ws"
      assert SessionLifecycle.session_workspace(%{}) == nil
      assert SessionLifecycle.session_worker_host(%{worker_host: "box"}) == "box"
      assert SessionLifecycle.session_worker_host(%{}) == nil
      assert SessionLifecycle.session_backend!(%{backend: "claude-repl"}) == "claude-repl"
      assert SessionLifecycle.session_backend_label(%{backend: "claude-repl"}) == "claude-repl"
    end

    test "session_backend!/1 raises rather than substituting the configured agent kind" do
      for session <- [%{}, %{backend: nil}, %{backend: :claude}, %{thread_id: "t-1"}] do
        error =
          assert_raise ArgumentError, fn -> SessionLifecycle.session_backend!(session) end

        assert error.message =~ inspect(session)
        assert error.message =~ "expected a binary :backend"
      end
    end

    test "session_backend_label/1 reports unknown rather than naming a backend it never observed" do
      # `unknown` is not a registered backend, so a reporting surface can never
      # mistake this label for a real provider the way the old configured
      # default could.
      refute "unknown" in CodingAgent.known_backends()

      for session <- [%{}, %{backend: nil}, %{backend: :claude}, %{thread_id: "t-1"}] do
        assert SessionLifecycle.session_backend_label(session) == "unknown"
      end
    end
  end

  describe "workspace containment" do
    test "accepts every valid session shape when local process-group discovery is unavailable" do
      for {shape, session, worker_host} <- [
            {"headless Claude", %{backend: "claude", metadata: %{claude_app_server_pid: "424242"}}, nil},
            {"Claude REPL", %{backend: "claude-repl", os_pid: 424_242}, nil},
            {"remote Codex", %{backend: "codex", metadata: %{codex_app_server_pid: "424242"}}, "worker-a"},
            {"local Codex", %{backend: "codex", metadata: %{codex_app_server_pid: "424242"}}, nil},
            {"in-process OpenAI-compatible", %{backend: "deepseek", session_pid: self()}, nil}
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
end
