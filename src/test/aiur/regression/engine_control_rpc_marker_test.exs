defmodule Aiur.Regression.EngineControlRpcMarkerTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  describe "control RPC exit-marker protocol (FI-CLI-029)" do
    test "a zero marker yields exit 0 and :ok/blank noise lines are filtered" do
      rel = fake_release()
      state = tmp_state()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      echo ":ok"
      echo ""
      echo "row1"
      echo "__AIUR_CONTROL_EXIT__:0"
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
        )

      assert out =~ "CODE=0"
      assert out =~ "row1"
      refute out =~ ":ok"
    end

    test "a nonzero marker propagates as the exit code" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"__AIUR_CONTROL_EXIT__:1\"\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_rpc_captured("Aiur.AgentControlCLI.status()", [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state}
        ])

      assert out =~ "CODE=1"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "failed with exit 1 and returned no diagnostic output"
      refute out =~ "returned no exit marker"
      refute out =~ "no running aiur node"
    end

    test "silent executor failures name the attempted decision, version, and endpoint" do
      for command <- ["executor-answer", "executor-escalate"] do
        rel = fake_release()
        state = tmp_state()
        File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"__AIUR_CONTROL_EXIT__:1\"\n")
        File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

        on_exit(fn ->
          File.rm_rf(rel)
          File.rm_rf(state)
        end)

        {out, 0} =
          run_control_rpc_captured(
            "Aiur.AgentControlCLI.executor_answer([])",
            [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}],
            "AIUR_CONTROL_COMMAND='#{command}'\nAIUR_CONTROL_ATTEMPT_CONTEXT='decision ID decision:42 with expected version 3'"
          )

        assert out =~ "CODE=1"
        assert out =~ "STDOUT_BYTES=0"
        assert out =~ "STDERR_LINES=1"
        assert out =~ "decision ID decision:42"
        assert out =~ "expected version 3"
        assert out =~ "daemon endpoint aiur-enginetest-"
        assert out =~ "Outcome is unknown"
      end
    end

    test "timed out executor failures preserve the attempted decision, version, and endpoint" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\nsleep 10\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_rpc_captured(
          "Aiur.AgentControlCLI.executor_answer([])",
          [
            {"AIUR_RELEASE_DIR", rel},
            {"AIUR_BG_STATE_DIR", state},
            {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "1"}
          ],
          ~s|AIUR_CONTROL_COMMAND='executor-answer'\nAIUR_CONTROL_ATTEMPT_CONTEXT='decision ID decision:42 with expected version 3'|
        )

      assert out =~ "CODE=124"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "timed out after 1s"
      assert out =~ "decision ID decision:42"
      assert out =~ "expected version 3"
      assert out =~ "daemon endpoint aiur-enginetest-"
    end

    test "a forwarded application error is printed without exposing its protocol marker" do
      rel = fake_release()
      state = tmp_state()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      echo "__AIUR_CONTROL_ERROR__:aiur: status query timed out after 5s; outcome is unknown"
      echo "__AIUR_CONTROL_EXIT__:124"
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_rpc_captured("Aiur.AgentControlCLI.status()", [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state}
        ])

      assert out =~ "CODE=124"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "aiur: status query timed out after 5s; outcome is unknown"
      refute out =~ "__AIUR_CONTROL_ERROR__"
      refute out =~ "__AIUR_CONTROL_EXIT__"
    end

    test "executor application errors cross the real guarded RPC marker seam" do
      rel = fake_release()
      state = tmp_state()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      set -euo pipefail
      cd "$AIUR_SOURCE_ROOT"
      exec mise exec -- mix run --no-start -e "${@: -1}" 2>/dev/null
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      expression = """
      Aiur.AgentControlCLI.executor_answer(decision_id: "decision:42", expected_version: 3, option_id: "yes", rationale: "why", idempotency_key: "key")
      Aiur.AgentControlCLI.executor_escalate(decision_id: "decision:42", expected_version: 3, reason: "operator judgment required")
      """

      {out, 0} =
        run_control_rpc_captured(
          expression,
          [
            {"AIUR_RELEASE_DIR", rel},
            {"AIUR_BG_STATE_DIR", state},
            {"AIUR_SOURCE_ROOT", Path.expand("../../..", __DIR__)},
            {"MIX_ENV", "test"}
          ],
          ~s|probe_node_liveness() { printf up; }\nAIUR_CONTROL_COMMAND='executor command'|
        )

      assert out =~ "CODE=1"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=2"
      assert out =~ "aiur: failed to answer Command ({:store_unavailable,"
      assert out =~ "aiur: failed to escalate Command ({:store_unavailable,"
      refute out =~ "returned no diagnostic output"
      refute out =~ "__AIUR_CONTROL_ERROR__"
    end

    test "a missing marker is an error" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\necho hello\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
        )

      assert out =~ "CODE=1"
      assert out =~ "returned no exit marker"
    end

    test "a hung rpc is killed and surfaces exit 124" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\nsleep 5\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_sourced_engine(
          ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
          [
            {"AIUR_RELEASE_DIR", rel},
            {"AIUR_BG_STATE_DIR", state},
            {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "1"}
          ]
        )

      assert out =~ "CODE=124"
      assert out =~ "timed out after 1s"
    end

    test "a timed-out rpc discards partial command output and emits one diagnostic line" do
      rel = fake_release()
      state = tmp_state()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      echo "ISSUE  STATE"
      echo "#44    working"
      sleep 5
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_rpc_captured("Aiur.AgentControlCLI.agents()", [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "1"}
        ])

      assert out =~ "CODE=124"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "timed out after 1s"
      assert out =~ "outcome is unknown"
      assert out =~ "partial output was discarded"
      refute out =~ "ISSUE  STATE"
      refute out =~ "#44    working"
    end

    test "a silent streaming rpc failure emits a diagnostic" do
      rel = fake_release()
      state = tmp_state()
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\nexit 9\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_captured("run_control_stream", "Aiur.AgentControlCLI.executor_listen()", [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state}
        ])

      assert out =~ "CODE=9"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "aiur: streaming control RPC failed with exit 9"
    end

    test "an rpc that dies without a word names the command instead of pointing at nothing (#1684)" do
      rel = fake_release()
      state = tmp_state()
      # `elixir --rpc-eval` kills itself with no message when the evaluated
      # expression exits — what a GenServer call timing out against a saturated
      # daemon does. This is the shape that produced exit 1 with an empty buffer.
      File.write!(Path.join([rel, "bin", "aiur"]), "#!/usr/bin/env bash\nexit 1\n")
      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      {out, 0} =
        run_control_rpc_captured(
          "Aiur.AgentControlCLI.status()",
          [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}],
          ~s|probe_node_liveness() { printf up; }\nAIUR_CONTROL_COMMAND=status|
        )

      assert out =~ "CODE=1"
      assert out =~ "STDOUT_BYTES=0"
      assert out =~ "STDERR_LINES=1"
      assert out =~ "aiur: status failed against"
      assert out =~ "with no diagnostic output (node is running); outcome is unknown"
      refute out =~ "see the error above"
    end

    test "every read-only command surfaces a diagnostic on each silent-failure shape (#1684)" do
      state = tmp_state()
      on_exit(fn -> File.rm_rf(state) end)

      shapes = silent_failure_shapes()

      for command <- ~w(status agents watch alerts usage commands analytics),
          {shape, body, timeout_seconds} <- shapes do
        rel = fake_release()
        File.write!(Path.join([rel, "bin", "aiur"]), body)
        File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)
        on_exit(fn -> File.rm_rf(rel) end)

        {out, 0} =
          run_control_rpc_captured(
            "Aiur.AgentControlCLI.#{command}()",
            [
              {"AIUR_RELEASE_DIR", rel},
              {"AIUR_BG_STATE_DIR", state},
              {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", timeout_seconds}
            ],
            ~s|probe_node_liveness() { printf up; }\nAIUR_CONTROL_COMMAND='#{command}'|
          )

        context = "#{command} / #{shape}: #{out}"

        refute out =~ "CODE=0", context
        assert out =~ ~r/STDERR_LINES=[1-9]/, context
        assert out =~ "aiur: #{command} ", context
      end
    end

    test "every mutating command exits non-zero with stderr on each silent-failure shape (#1736)" do
      state = tmp_state()
      on_exit(fn -> File.rm_rf(state) end)

      shapes = silent_failure_shapes()

      commands = [
        {"set max-agents", "Aiur.AgentControlCLI.set_max_agents(2)"},
        {"pause", ~s|Aiur.AgentControlCLI.pause(["44"])|},
        {"resume", ~s|Aiur.AgentControlCLI.resume(["44"])|},
        {"reset-budget", ~s|Aiur.AgentControlCLI.reset_budget(["44"])|},
        {"pause", "Aiur.AgentControlCLI.pause_global()"},
        {"resume", "Aiur.AgentControlCLI.resume_global()"}
      ]

      for {command, expression} <- commands,
          {shape, body, timeout_seconds} <- shapes do
        rel = fake_release()
        File.write!(Path.join([rel, "bin", "aiur"]), body)
        File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)
        on_exit(fn -> File.rm_rf(rel) end)

        {out, 0} =
          run_control_rpc_captured(
            expression,
            [
              {"AIUR_RELEASE_DIR", rel},
              {"AIUR_BG_STATE_DIR", state},
              {"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", timeout_seconds}
            ],
            ~s|probe_node_liveness() { printf up; }\nAIUR_CONTROL_COMMAND='#{command}'|
          )

        context = "#{command} / #{shape}: #{out}"

        refute out =~ "CODE=0", context
        assert out =~ "STDOUT_BYTES=0", context
        assert out =~ ~r/STDERR_LINES=[1-9]/, context
        assert out =~ "aiur: #{command} ", context
      end
    end

    test "real mutating entrypoint errors cross the launcher marker seam (#1736)" do
      state = tmp_state()
      rel = fake_release()

      File.write!(Path.join([rel, "bin", "aiur"]), """
      #!/usr/bin/env bash
      set -euo pipefail
      cd "$AIUR_SOURCE_ROOT"
      exec mise exec -- mix run --no-start -e "${@: -1}" 2>/dev/null
      """)

      File.chmod!(Path.join([rel, "bin", "aiur"]), 0o755)

      on_exit(fn ->
        File.rm_rf(rel)
        File.rm_rf(state)
      end)

      commands = [
        {"set max-agents", "Aiur.AgentControlCLI.set_max_agents(2)"},
        {"pause", ~s|Aiur.AgentControlCLI.pause(["44"])|},
        {"resume", ~s|Aiur.AgentControlCLI.resume(["44"])|},
        {"reset-budget", ~s|Aiur.AgentControlCLI.reset_budget(["44"])|},
        {"pause", "Aiur.AgentControlCLI.pause_global()"},
        {"resume", "Aiur.AgentControlCLI.resume_global()"}
      ]

      for {command, expression} <- commands do
        {out, 0} =
          run_control_rpc_captured(
            expression,
            [
              {"AIUR_RELEASE_DIR", rel},
              {"AIUR_BG_STATE_DIR", state},
              {"AIUR_SOURCE_ROOT", Path.expand("../../..", __DIR__)},
              {"MIX_ENV", "test"}
            ],
            ~s|probe_node_liveness() { printf up; }\nAIUR_CONTROL_COMMAND='#{command}'|
          )

        context = "#{command}: #{out}"
        assert out =~ "CODE=1", context
        assert out =~ "STDOUT_BYTES=0", context
        assert out =~ ~r/STDERR_LINES=[1-9]/, context
      end
    end

    test "the marker and readiness literals are pinned across both languages" do
      cli = File.read!(Path.expand("../../../lib/aiur/control_cli/protocol.ex", __DIR__))
      engine = Aiur.EngineSource.text()

      assert cli =~ ~s|@exit_marker "__AIUR_CONTROL_EXIT__:"|
      assert cli =~ ~s|@error_marker "__AIUR_CONTROL_ERROR__:"|
      assert engine =~ ~s|marker="__AIUR_CONTROL_EXIT__:"|
      assert engine =~ ~s|error_marker="__AIUR_CONTROL_ERROR__:"|
      assert engine =~ "__AIUR_CONTROL_READY__"
      assert engine =~ "__AIUR_CONTROL_NOT_READY__"
    end
  end
end
