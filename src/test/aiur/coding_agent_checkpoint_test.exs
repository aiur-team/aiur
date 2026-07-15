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

  test "Codex adapter exits after two operator deliveries and idle completion" do
    test_root = Path.join(System.tmp_dir!(), "aiur-codex-operator-idle-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CODEX-OPERATOR-IDLE")
      trace_file = Path.join(test_root, "codex.trace")
      binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, codex_operator_idle_script())
      File.chmod!(binary, 0o755)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEX_TRACE")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        command: "#{binary} app-server",
        agent_turn_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-codex-operator-idle",
        identifier: "MT-CODEX-OPERATOR-IDLE",
        title: "Operator idle completion",
        description: "complete after multiple accepted operator turns report idle",
        state: "In Progress",
        url: "https://example.org/issues/MT-CODEX-OPERATOR-IDLE",
        labels: []
      }

      assert {:ok, session} = CodexAgent.start_session(workspace)

      try do
        callback = queued_follow_ups_callback(self(), ["first repair", "second repair"])

        assert {:ok, _turn_session} =
                 CodexAgent.run_turn(
                   session,
                   "initial prompt",
                   issue,
                   on_safe_checkpoint: callback
                 )

        assert_receive {:delivered, %{turn_id: "turn-operator-1"}}
        assert_receive {:delivered, %{turn_id: "turn-operator-2"}}
        refute_receive {:delivery_failed, _reason}

        assert_stable_turn_texts(trace_file, ["initial prompt", "first repair", "second repair"])
      after
        CodexAgent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "Codex adapter interrupts for a current-issue deliver-now queue update" do
    test_root = Path.join(System.tmp_dir!(), "aiur-codex-checkpoint-current-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CP-CODEX-CURRENT")
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
        id: "issue-checkpoint-codex-current",
        identifier: "MT-CP-CODEX-CURRENT",
        title: "Checkpoint current issue",
        description: "interrupt for current issue delivery",
        state: "In Progress",
        url: "https://example.org/issues/MT-CP-CODEX-CURRENT",
        labels: []
      }

      assert {:ok, session} = CodexAgent.start_session(workspace)

      try do
        callback = one_shot_follow_up_callback(self(), "focus on auth first", issue.identifier)

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
        assert_traced_method(trace_file, "turn/interrupt")
      after
        CodexAgent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "Codex adapter treats idle thread status as turn completion" do
    test_root = Path.join(System.tmp_dir!(), "aiur-codex-idle-status-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CODEX-IDLE")
      trace_file = Path.join(test_root, "codex.trace")
      binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, codex_idle_status_script())
      File.chmod!(binary, 0o755)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEX_TRACE")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        command: "#{binary} app-server",
        agent_turn_timeout_ms: 80
      )

      issue = %Issue{
        id: "issue-codex-idle",
        identifier: "MT-CODEX-IDLE",
        title: "Idle status completion",
        description: "complete when Codex reports the thread idle",
        state: "In Progress",
        url: "https://example.org/issues/MT-CODEX-IDLE",
        labels: []
      }

      assert {:ok, session} = CodexAgent.start_session(workspace)

      try do
        assert {:ok, _turn_session} = CodexAgent.run_turn(session, "initial prompt", issue)
        assert_stable_turn_texts(trace_file, ["initial prompt"])
      after
        CodexAgent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "Codex adapter ignores idle thread status before a turn starts" do
    test_root = Path.join(System.tmp_dir!(), "aiur-codex-prestart-idle-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CODEX-PRESTART-IDLE")
      trace_file = Path.join(test_root, "codex.trace")
      binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, codex_prestart_idle_status_script())
      File.chmod!(binary, 0o755)

      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEX_TRACE")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "codex",
        command: "#{binary} app-server",
        agent_turn_timeout_ms: 1_000
      )

      issue = %Issue{
        id: "issue-codex-prestart-idle",
        identifier: "MT-CODEX-PRESTART-IDLE",
        title: "Pre-start idle status",
        description: "ignore idle before the turn has started",
        state: "In Progress",
        url: "https://example.org/issues/MT-CODEX-PRESTART-IDLE",
        labels: []
      }

      test_pid = self()

      on_message = fn message ->
        if message.event == :notification do
          send(test_pid, {:notification_method, get_in(message, [:payload, "method"])})
        end
      end

      assert {:ok, session} = CodexAgent.start_session(workspace)

      try do
        assert {:ok, _turn_session} = CodexAgent.run_turn(session, "initial prompt", issue, on_message: on_message)
        assert_received {:notification_method, "turn/started"}
        assert_stable_turn_texts(trace_file, ["initial prompt"])
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

  test "Claude adapter interrupts for a current-issue deliver-now queue update" do
    test_root = Path.join(System.tmp_dir!(), "aiur-claude-checkpoint-current-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(Config.workspace_root(), "MT-CP-CLAUDE-CURRENT")
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
        id: "issue-checkpoint-claude-current",
        identifier: "MT-CP-CLAUDE-CURRENT",
        title: "Claude checkpoint current issue",
        description: "interrupt for current issue delivery",
        state: "In Progress",
        url: "https://example.org/issues/MT-CP-CLAUDE-CURRENT",
        labels: []
      }

      assert {:ok, session} = ClaudeAgent.start_session(workspace)

      try do
        callback = one_shot_follow_up_callback(self(), "follow up in claude", issue.identifier)

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
        assert_traced_method(trace_file, "turn/interrupt")
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

  defp queued_follow_ups_callback(test_pid, texts) do
    fn _checkpoint ->
      index = Process.get({__MODULE__, :follow_up_index}, 0)

      case Enum.fetch(texts, index) do
        {:ok, text} ->
          Process.put({__MODULE__, :follow_up_index}, index + 1)
          deliver_text_result(test_pid, text)

        :error ->
          :noop
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

  defp assert_traced_method(trace_file, method, attempts \\ 20)

  defp assert_traced_method(trace_file, method, 0) do
    assert method in traced_methods(trace_file)
  end

  defp assert_traced_method(trace_file, method, attempts) do
    if method in traced_methods(trace_file) do
      :ok
    else
      Process.sleep(10)
      assert_traced_method(trace_file, method, attempts - 1)
    end
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

  defp codex_operator_idle_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-operator-idle.trace}"
    turn_start_count=0

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-operator-idle"}}}'
          ;;
        *'"method":"turn/start"'*)
          turn_start_count=$((turn_start_count + 1))
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')

          case "$turn_start_count" in
            1)
              printf '{"id":%s,"result":{"turn":{"id":"turn-main","status":"inProgress"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-main","status":"inProgress"}}}'
              printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"first checkpoint"}]}}'
              printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"second checkpoint"}]}}'
              ;;
            2)
              printf '{"id":%s,"result":{"turn":{"id":"turn-operator-1","status":"inProgress"}}}\\n' "$request_id"
              ;;
            3)
              printf '{"id":%s,"result":{"turn":{"id":"turn-operator-2","status":"inProgress"}}}\\n' "$request_id"
              printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
              printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-main","status":"completed"}}}'
              ;;
          esac
          ;;
      esac
    done
    """
  end

  defp codex_idle_status_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-idle-status.trace}"

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-idle-status"}}}'
          ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{"turn":{"id":"turn-idle-status"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-idle-status"}}}'
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"status":"completed"}}}'
          printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
          ;;
      esac
    done
    """
  end

  defp codex_prestart_idle_status_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-prestart-idle-status.trace}"

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-prestart-idle-status"}}}'
          ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{"turn":{"id":"turn-prestart-idle-status"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
          sleep 0.1
          printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-prestart-idle-status"}}}'
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"status":"completed"}}}'
          printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
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
