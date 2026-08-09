defmodule Aiur.CodingAgentCheckpointTest do
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent

  # Single-writer regression (#1247): a safe checkpoint that lands while the
  # parent provider turn is live must NOT open a second `turn/start` on the same
  # thread — aiur-claude would spawn a second concurrent CLI writer in the shared
  # workspace. The checkpoint handler is not even invoked; the item stays queued
  # for the turn-boundary drain.
  test "Codex adapter does not open a second turn from a safe checkpoint while the parent turn is live" do
    with_checkpoint_workspace("MT-SW-CODEX", :codex, codex_single_writer_script(), fn session, issue, trace_file ->
      callback = deliver_on_checkpoint_callback(self(), "should not deliver")

      assert {:ok, _turn_session} =
               CodexAgent.run_turn(session, "initial prompt", issue, on_safe_checkpoint: callback)

      refute_receive {:checkpoint_seen, _checkpoint}
      refute_receive {:delivered, _payload}

      assert_stable_turn_texts(trace_file, ["initial prompt"])
      refute_traced_method(trace_file, "turn/interrupt")
    end)
  end

  test "Claude adapter does not open a second turn from a safe checkpoint while the parent turn is live" do
    with_checkpoint_workspace("MT-SW-CLAUDE", :claude, claude_single_writer_script(), fn session, issue, trace_file ->
      callback = deliver_on_checkpoint_callback(self(), "should not deliver")

      assert {:ok, _turn_session} =
               ClaudeAgent.run_turn(session, "initial prompt", issue, on_safe_checkpoint: callback)

      refute_receive {:checkpoint_seen, _checkpoint}
      refute_receive {:delivered, _payload}

      assert_stable_turn_texts(trace_file, ["initial prompt"])
      refute_traced_method(trace_file, "turn/interrupt")
    end)
  end

  # A current-issue deliver-now queue update still reaches the agent mid-turn,
  # but through the acknowledged `turn/interrupt` steering primitive (which ends
  # the parent turn) — never a concurrent second writer.
  test "Codex adapter interrupts the parent turn for a current-issue deliver-now update" do
    with_checkpoint_workspace("MT-INT-CODEX", :codex, codex_interrupt_script(), fn session, issue, trace_file ->
      send(self(), {:agent_queue_updated, issue.identifier, 999, true})

      assert {:ok, _turn_session} = CodexAgent.run_turn(session, "initial prompt", issue)

      assert_traced_method(trace_file, "turn/interrupt")
      assert_stable_turn_texts(trace_file, ["initial prompt"])
    end)
  end

  test "Claude adapter interrupts the parent turn for a current-issue deliver-now update" do
    with_checkpoint_workspace("MT-INT-CLAUDE", :claude, claude_interrupt_script(), fn session, issue, trace_file ->
      send(self(), {:agent_queue_updated, issue.identifier, 999, true})

      assert {:ok, _turn_session} = ClaudeAgent.run_turn(session, "initial prompt", issue)

      assert_traced_method(trace_file, "turn/interrupt")
      assert_stable_turn_texts(trace_file, ["initial prompt"])
    end)
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

      # Synced, not best-effort: `write_workflow_file!/2` fires a `force_reload`
      # wrapped in `catch :exit, _ -> :ok`, so under CI contention a call that
      # outlasts its 5s GenServer timeout is swallowed silently. `Config` then
      # still serves the pre-write cache and `start_session/1` spawns the
      # DEFAULT provider command (`codex app-server` / `aiur-claude`) instead of
      # this fixture — neither exists on a CI runner, so bash exits 127 and the
      # session fails with `{:port_exit, 127}` or, when the exit lands before
      # the `initialize` write, `:port_closed`.
      write_workflow_file_synced!(Workflow.workflow_file_path(),
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

      # Synced: see the note above — a swallowed `force_reload` leaves `Config`
      # serving the pre-write cache and spawns the default provider command.
      write_workflow_file_synced!(Workflow.workflow_file_path(),
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

  # Boots a fake app-server for the given backend, runs `body.(session, issue,
  # trace_file)`, and tears everything down. Keeps each behavioral test focused
  # on its assertions rather than the workspace/session boilerplate.
  defp with_checkpoint_workspace(identifier, backend, script, body) do
    test_root = Path.join(System.tmp_dir!(), "aiur-checkpoint-#{identifier}-#{System.unique_integer([:positive])}")

    {agent, trace_env} =
      case backend do
        :codex -> {CodexAgent, "SYMP_TEST_CODEX_TRACE"}
        :claude -> {ClaudeAgent, "SYMP_TEST_CLAUDE_TRACE"}
      end

    try do
      workspace = Path.join(Config.workspace_root(), identifier)
      trace_file = Path.join(test_root, "provider.trace")
      binary = Path.join(test_root, "fake-provider")

      File.mkdir_p!(workspace)
      File.mkdir_p!(test_root)
      File.write!(binary, script)
      File.chmod!(binary, 0o755)

      System.put_env(trace_env, trace_file)
      on_exit(fn -> System.delete_env(trace_env) end)

      # Synced: see the note above — a swallowed `force_reload` leaves `Config`
      # serving the pre-write cache and spawns the default provider command.
      write_workflow_file_synced!(Workflow.workflow_file_path(),
        agent_kind: Atom.to_string(backend),
        command: "#{binary} app-server",
        agent_turn_timeout_ms: 2_000
      )

      issue = %Issue{
        id: "issue-#{identifier}",
        identifier: identifier,
        title: "Checkpoint single-writer",
        description: "single-writer checkpoint semantics",
        state: "In Progress",
        url: "https://example.org/issues/#{identifier}",
        labels: []
      }

      assert {:ok, session} = agent.start_session(workspace)

      try do
        body.(session, issue, trace_file)
      after
        agent.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  defp deliver_on_checkpoint_callback(test_pid, text) do
    fn checkpoint ->
      send(test_pid, {:checkpoint_seen, checkpoint})
      on_success = fn payload -> send(test_pid, {:delivered, payload}) end
      on_failure = fn reason -> send(test_pid, {:delivery_failed, reason}) end
      {:deliver_text, text, on_success, on_failure}
    end
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

  # Parent turn responds to a checkpoint-triggering notification and then
  # completes on its own. A second `turn/start` (which the single-writer guard
  # must prevent) would be answered with `turn-followup`, surfacing in the trace.
  defp codex_single_writer_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-single-writer.trace}"
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
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-single"}}}'
          ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          if [ "$first_turn_started" -eq 0 ]; then
            first_turn_started=1
            printf '{"id":%s,"result":{"turn":{"id":"turn-main","status":"inProgress"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-main","status":"inProgress"}}}'
            printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-main","status":"completed"}}}'
          else
            printf '{"id":%s,"result":{"turn":{"id":"turn-followup","status":"inProgress"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-followup","status":"completed"}}}'
          fi
          ;;
      esac
    done
    """
  end

  defp claude_single_writer_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-single-writer.trace}"
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
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-single"}}}'
          ;;
        *'"method":"turn/start"'*)
          if [ "$first_turn_started" -eq 0 ]; then
            first_turn_started=1
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
            printf '%s\\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"keep going"}]}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-main","status":"completed"}}}'
          else
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"id":%s,"result":{"turn":{"id":"turn-followup"}}}\\n' "$request_id"
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-followup","status":"completed"}}}'
          fi
          ;;
      esac
    done
    """
  end

  # Parent turn stays open until it is interrupted; the interrupt is acknowledged
  # (Codex additionally reports idle) so the turn terminates as interrupted.
  defp codex_interrupt_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex-interrupt.trace}"

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-interrupt"}}}'
          ;;
        *'"method":"turn/interrupt"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{}}\\n' "$request_id"
          printf '%s\\n' '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
          ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{"turn":{"id":"turn-main","status":"inProgress"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/started","params":{"turn":{"id":"turn-main","status":"inProgress"}}}'
          ;;
      esac
    done
    """
  end

  defp claude_interrupt_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-interrupt.trace}"

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-interrupt"}}}'
          ;;
        *'"method":"turn/interrupt"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-main","status":"interrupted"}}}'
          ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-main"}}}'
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
end
