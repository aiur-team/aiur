defmodule Aiur.AgentRunner.SessionLifecycle.StartupTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Issue

  describe "start_agent_session/3" do
    test "keeps the provider's established model, falling back to the requested model when absent" do
      opts = [backend: "muse", model: "requested-model"]

      for reported <- ["native-model", " native-model "] do
        start_fun = fn _workspace, _opts -> {:ok, %{model: reported}} end
        assert {:ok, %{model: ^reported}} = SessionLifecycle.start_agent_session("/ws", opts, start_fun)
      end

      for reported <- [nil, "", "  "] do
        start_fun = fn _workspace, _opts -> {:ok, %{model: reported}} end
        assert {:ok, %{model: "requested-model"}} = SessionLifecycle.start_agent_session("/ws", opts, start_fun)
      end

      assert {:ok, %{model: "requested-model"}} =
               SessionLifecycle.start_agent_session("/ws", opts, fn _workspace, _opts -> {:ok, %{}} end)
    end

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

      assert {:ok, %{backend: "claude", attempt_id: "attempt-claude"} = fallback_session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [
                   backend: "claude-repl",
                   model: "opus",
                   effort: "max",
                   remote_control: true,
                   attempt_id: "attempt-claude"
                 ],
                 start_fun
               )

      assert_received {:attempt, "claude-repl", true}
      assert_received {:attempt, "claude", nil}

      issue = %Issue{id: "issue-fallback-execution", identifier: "FALLBACK-EXECUTION"}
      assert :ok = SessionLifecycle.report_session_execution(self(), issue, fallback_session)

      assert_receive {:session_execution_info, "issue-fallback-execution", %{backend: "claude", requested_model: "opus", effort: nil}}, 1000
    end

    test "warns when dropping an effort the started backend cannot use" do
      start_fun = fn _workspace, _opts -> {:ok, %{handle: :headless}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{backend: "claude", effort: nil}} =
                   SessionLifecycle.start_agent_session(
                     "/ws",
                     [backend: "claude", model: nil, effort: "xhigh"],
                     start_fun
                   )
        end)

      assert log =~ "Ignoring effort \"xhigh\" for backend claude"
    end

    test "keeps an effort the started backend supports, without warning" do
      start_fun = fn _workspace, _opts -> {:ok, %{handle: :codex}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{backend: "codex", effort: "high"}} =
                   SessionLifecycle.start_agent_session(
                     "/ws",
                     [backend: "codex", model: nil, effort: "high"],
                     start_fun
                   )
        end)

      refute log =~ "Ignoring effort"
    end

    test "the RC transport (claude-repl) retains its effort without warning" do
      start_fun = fn _workspace, _opts -> {:ok, %{handle: :repl}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{backend: "claude-repl", effort: "high"}} =
                   SessionLifecycle.start_agent_session(
                     "/ws",
                     [backend: "claude-repl", model: "opus", effort: "high"],
                     start_fun
                   )
        end)

      refute log =~ "Ignoring effort"
    end

    test "warns when the claude-repl->claude fallback drops a repl effort" do
      start_fun = fn _workspace, opts ->
        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{handle: :headless}}
        end
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{backend: "claude", effort: nil}} =
                   SessionLifecycle.start_agent_session(
                     "/ws",
                     [backend: "claude-repl", model: "opus", effort: "high", remote_control: true],
                     start_fun
                   )
        end)

      assert log =~ "Ignoring effort \"high\" for backend claude"
    end

    test "non-repl start errors propagate unchanged" do
      start_fun = fn _workspace, _opts -> {:error, :boom} end

      assert {:error, :boom} = SessionLifecycle.start_agent_session("/ws", [backend: "claude", model: nil], start_fun)
    end

    test "keeps only the revocation handle after passing telemetry launch settings to Claude" do
      launch = %{id: make_ref(), env: [{"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer synthetic"}]}

      start_fun = fn _workspace, opts ->
        assert Keyword.fetch!(opts, :telemetry_launch) == launch
        {:ok, %{handle: :claude}}
      end

      assert {:ok, %{backend: "claude", telemetry_launch: %{id: launch_id}}} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [backend: "claude", model: nil, telemetry_launch: launch],
                 start_fun
               )

      assert launch_id == launch.id
    end

    test "does not reuse a REPL telemetry capability when fallback renewal is unavailable" do
      launch = %{id: make_ref(), env: [{"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer synthetic"}]}
      parent = self()

      start_fun = fn _workspace, opts ->
        send(parent, {:fallback_attempt, Keyword.fetch!(opts, :backend), Keyword.get(opts, :telemetry_launch)})

        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{handle: :headless}}
        end
      end

      assert {:ok, %{backend: "claude"} = session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: nil, telemetry_launch: launch],
                 start_fun
               )

      refute Map.has_key?(session, :telemetry_launch)
      assert_received {:fallback_attempt, "claude-repl", ^launch}
      assert_received {:fallback_attempt, "claude", nil}
    end

    test "passes a freshly correlated telemetry capability to the headless fallback" do
      repl_launch = %{id: make_ref(), env: [{"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer repl"}]}
      headless_launch = %{id: make_ref(), env: [{"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer headless"}]}
      parent = self()

      start_fun = fn _workspace, opts ->
        send(parent, {:renewed_fallback_attempt, Keyword.fetch!(opts, :backend), Keyword.get(opts, :telemetry_launch)})

        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{handle: :headless}}
        end
      end

      fallback_launch_fun = fn "claude" -> {:ok, headless_launch} end

      assert {:ok, %{backend: "claude", telemetry_launch: %{id: launch_id}}} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [
                   backend: "claude-repl",
                   model: nil,
                   telemetry_launch: repl_launch,
                   telemetry_fallback_launch_fun: fallback_launch_fun
                 ],
                 start_fun
               )

      assert launch_id == headless_launch.id
      assert_received {:renewed_fallback_attempt, "claude-repl", ^repl_launch}
      assert_received {:renewed_fallback_attempt, "claude", ^headless_launch}
    end
  end
end
