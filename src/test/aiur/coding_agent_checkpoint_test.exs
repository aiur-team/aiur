defmodule Aiur.CodingAgentCheckpointTest do
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent

  test "Codex adapter starts a queued follow-up turn from a safe checkpoint" do
    test_root = Path.join(System.tmp_dir!(), "aiur-codex-checkpoint-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CP-CODEX")
      trace_file = Path.join(test_root, "codex.trace")
      binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, codex_checkpoint_script())
      File.chmod!(binary, 0o755)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEX_TRACE")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        command: "#{binary} app-server"
      )

      issue = %Issue{
        id: "issue-checkpoint-codex",
        identifier: "MT-CP-CODEX",
        title: "Checkpoint follow-up",
        description: "queue a follow-up turn from a checkpoint",
        state: "In Progress",
        url: "https://example.org/issues/MT-CP-CODEX",
        labels: []
      }

      assert {:ok, session} = CodexAgent.start_session(workspace)

      try do
        callback = one_shot_follow_up_callback(self(), "focus on auth first", "MT-UNRELATED-CODEX")

        assert {:ok, _turn_session} =
                 CodexAgent.run_turn(
                   session,
                   "initial prompt",
                   issue,
                   on_safe_checkpoint: callback
                 )

        assert_receive {:delivered, %{turn_id: "turn-followup"}}
        refute_receive {:delivery_failed, _reason}

        assert_stable_turn_texts(trace_file, ["initial prompt", "focus on auth first"])
        refute_traced_method(trace_file, "turn/interrupt")
      after
        CodexAgent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "Claude adapter starts a queued follow-up turn from a safe checkpoint" do
    test_root = Path.join(System.tmp_dir!(), "aiur-claude-checkpoint-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CP-CLAUDE")
      trace_file = Path.join(test_root, "claude.trace")
      binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, claude_checkpoint_script())
      File.chmod!(binary, 0o755)

      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CLAUDE_TRACE")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        command: "#{binary} app-server"
      )

      issue = %Issue{
        id: "issue-checkpoint-claude",
        identifier: "MT-CP-CLAUDE",
        title: "Claude checkpoint follow-up",
        description: "queue a follow-up turn from a checkpoint",
        state: "In Progress",
        url: "https://example.org/issues/MT-CP-CLAUDE",
        labels: []
      }

      assert {:ok, session} = ClaudeAgent.start_session(workspace)

      try do
        callback = one_shot_follow_up_callback(self(), "follow up in claude", "MT-UNRELATED-CLAUDE")

        assert {:ok, _turn_session} =
                 ClaudeAgent.run_turn(
                   session,
                   "initial prompt",
                   issue,
                   on_safe_checkpoint: callback
                 )

        assert_receive {:delivered, %{turn_id: "turn-followup"}}
        refute_receive {:delivery_failed, _reason}

        assert_stable_turn_texts(trace_file, ["initial prompt", "follow up in claude"])
        refute_traced_method(trace_file, "turn/interrupt")
      after
        ClaudeAgent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  defp one_shot_follow_up_callback(test_pid, text, unrelated_issue_identifier) do
    fn checkpoint ->
      send(test_pid, {:checkpoint_seen, checkpoint})

      if Process.get({__MODULE__, :follow_up_sent}) do
        :noop
      else
        Process.put({__MODULE__, :follow_up_sent}, true)
        send(self(), {:agent_queue_updated, unrelated_issue_identifier, 999, true})

        deliver_text_result(test_pid, text)
      end
    end
  end

  defp deliver_text_result(test_pid, text) do
    on_success = fn payload -> send(test_pid, {:delivered, payload}) end
    on_failure = fn reason -> send(test_pid, {:delivery_failed, reason}) end
    {:deliver_text, text, on_success, on_failure}
  end

  defp assert_stable_turn_texts(trace_file, expected) do
    assert_turn_texts(trace_file, expected)
    Process.sleep(150)
    assert traced_turn_texts(trace_file) == expected
  end

  defp assert_turn_texts(trace_file, expected, attempts \\ 20)

  defp assert_turn_texts(trace_file, expected, 0) do
    assert traced_turn_texts(trace_file) == expected
  end

  defp assert_turn_texts(trace_file, expected, attempts) do
    if traced_turn_texts(trace_file) == expected do
      :ok
    else
      Process.sleep(10)
      assert_turn_texts(trace_file, expected, attempts - 1)
    end
  end

  defp traced_turn_texts(trace_file) do
    trace_file
    |> traced_json_frames()
    |> Enum.filter(&(&1["method"] == "turn/start"))
    |> Enum.map(fn payload ->
      get_in(payload, ["params", "input"])
      |> Enum.map_join("\n", &Map.get(&1, "text", ""))
    end)
  end

  defp refute_traced_method(trace_file, method) do
    refute method in traced_methods(trace_file)
  end

  defp traced_methods(trace_file) do
    trace_file
    |> traced_json_frames()
    |> Enum.map(& &1["method"])
    |> Enum.reject(&is_nil/1)
  end

  defp traced_json_frames(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(&String.trim_leading(&1, "JSON:"))
    |> Enum.map(&Jason.decode!/1)
  end

  defp codex_checkpoint_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-checkpoint.trace}"
    first_turn_started=0

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checkpoint"}}}'
          ;;
        *'"method":"turn/start"'*)
          if [ "$first_turn_started" -eq 0 ]; then
            first_turn_started=1
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
            printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
          else
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{"turn":{"id":"turn-followup"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
          fi
          ;;
      esac
    done
    """
  end

  defp claude_checkpoint_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-checkpoint.trace}"
    first_turn_started=0

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checkpoint"}}}'
          ;;
        *'"method":"turn/start"'*)
          if [ "$first_turn_started" -eq 0 ]; then
            first_turn_started=1
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
            printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
          else
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{"turn":{"id":"turn-followup"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
          fi
          ;;
      esac
    done
    """
  end
end
