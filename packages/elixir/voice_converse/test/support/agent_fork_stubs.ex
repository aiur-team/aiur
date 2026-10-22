defmodule VoiceConverse.AgentForkStubs do
  @moduledoc false
  # Stub `claude` and `codex` CLIs and parent sessions for the AgentFork tests.

  @parent_id "0d6b2a9c-7e11-4c55-9e1f-3f2c1d7e8a4b"

  @claude_help """
  Usage: claude [options]
    -p, --print  --resume <id>  --fork-session  --no-session-persistence  --permission-mode <mode>
    --tools <tools...>  --disallowedTools <tools...>  --strict-mcp-config  --settings <file-or-json>
    --permission-prompts <target>
    --max-turns <n>  --input-format <format>  --output-format <format>  --include-partial-messages  --verbose
  """

  def parent_id, do: @parent_id
  def claude_help, do: @claude_help

  def tmp_root do
    root = Path.join(System.tmp_dir!(), "agent_fork_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # A mid-edit worktree: one committed file with an uncommitted change.
  def git_repo(root) do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "lib.ex"), "v1\n")
    git(repo, ["init", "-q"])
    git(repo, ["add", "."])
    git(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])
    File.write!(Path.join(repo, "lib.ex"), "v2 in progress\n")
    repo
  end

  defp git(repo, args), do: {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  def claude_parent(root) do
    config_dir = Path.join(root, "claude-config")
    project_dir = Path.join([config_dir, "projects", "-repo"])
    File.mkdir_p!(project_dir)
    transcript = Path.join(project_dir, "#{@parent_id}.jsonl")

    # The parent is mid tool call: its last record is an open tool_use.
    File.write!(transcript, """
    {"type":"user","message":{"role":"user","content":"fix the retry"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{}}]}}
    """)

    %{config_dir: config_dir, project_dir: project_dir, transcript: transcript, repo: git_repo(root)}
  end

  def claude_handle(parent),
    do: %{harness: :claude_code, session_id: @parent_id, cwd: parent.repo, config_dir: parent.config_dir}

  # A stub `claude` that records argv, env, cwd and stdin. It misbehaves the way the real CLI
  # would without each read-only flag: without --fork-session it appends to the parent, without
  # --no-session-persistence it writes a session file, without plan mode or with hooks enabled it
  # edits the worktree (a SessionStart hook is arbitrary shell).
  def claude_stub(dir, parent, behaviour, help \\ @claude_help) do
    File.mkdir_p!(dir)

    body =
      case behaviour do
        :answer ->
          ~S"""
          echo '{"type":"system","subtype":"init"}'
          echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"It"}}}'
          echo '{"type":"result","subtype":"success","is_error":false,"result":"It hid the real error.","usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.01}'
          sleep 30
          """

        :hang ->
          ~S"""
          sleep 300 &
          echo $! > "$LOG/grandchild"
          wait
          """
      end

    write_exe(Path.join(dir, "claude"), """
    #!/bin/sh
    LOG='#{dir}'
    if [ "$1" = "--help" ]; then
    cat <<'HELP'
    #{help}
    HELP
    exit 0
    fi
    echo $$ > "$LOG/pid"
    printf '%s\\n' "$@" > "$LOG/argv"
    env > "$LOG/env"
    pwd > "$LOG/cwd"
    IFS= read -r line
    printf '%s\\n' "$line" > "$LOG/stdin"
    ARGS=" $* "
    case "$ARGS" in *" --fork-session "*) ;; *) echo '{"type":"user"}' >> '#{parent.transcript}' ;; esac
    case "$ARGS" in *" --no-session-persistence "*) ;; *) echo '{}' > '#{parent.project_dir}/fork-session.jsonl' ;; esac
    case "$ARGS" in *" --permission-mode plan "*) ;; *) echo edit > lib.ex ;; esac
    case "$ARGS" in *'"disableAllHooks":true'*) ;; *) echo hook > lib.ex ;; esac
    #{body}
    """)
  end

  def codex_parent(root) do
    codex_home = Path.join(root, "codex-home")
    sessions_dir = Path.join(codex_home, "sessions")
    File.mkdir_p!(sessions_dir)
    rollout = Path.join(sessions_dir, "rollout-#{@parent_id}.jsonl")
    File.write!(rollout, ~s({"type":"turn_context"}\n))
    %{codex_home: codex_home, sessions_dir: sessions_dir, rollout: rollout, repo: git_repo(root)}
  end

  def codex_handle(parent),
    do: %{harness: :codex, session_id: @parent_id, cwd: parent.repo, config_dir: parent.codex_home}

  # A stub `codex app-server` that records every JSON-RPC line. It misbehaves like the real
  # server would without each guard: a non-ephemeral fork writes a rollout file, a turn on the
  # parent appends to the parent's rollout, a turn without the read-only sandbox, or a server with
  # hooks or `notify` enabled, edits the worktree.
  def codex_stub(dir, parent, fork_thread) do
    write_exe(Path.join(dir, "codex"), """
    #!/bin/sh
    LOG='#{dir}'
    [ "$1" = "app-server" ] || exit 2
    printf '%s\\n' "$@" > "$LOG/argv"
    case " $* " in *" --disable hooks "*) ;; *) echo hook > lib.ex ;; esac
    case " $* " in *" notify=[] "*) ;; *) echo notify > lib.ex ;; esac
    WRITES=no
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$LOG/rpc"
      case "$line" in
        *'"method":"initialize"'*)
          echo '{"id":1,"result":{"userAgent":"fake"}}' ;;
        *'"method":"thread/fork"'*)
          case "$line" in *'"ephemeral":true'*) ;; *) echo '{}' > '#{parent.sessions_dir}/rollout-fork.jsonl' ;; esac
          case "$line" in *'"sandbox":"read-only"'*) ;; *) WRITES=yes ;; esac
          echo '{"id":2,"result":{"thread":{"id":"#{fork_thread}"}}}' ;;
        *'"method":"thread/resume"'*)
          echo '{"resumed":true}' >> '#{parent.rollout}' ;;
        *'"method":"turn/start"'*)
          case "$line" in *'"threadId":"#{@parent_id}"'*) echo '{"turn":true}' >> '#{parent.rollout}' ;; esac
          case "$line" in *'"readOnly"'*) ;; *) WRITES=yes ;; esac
          [ "$WRITES" = yes ] && echo edit > lib.ex
          echo '{"id":3,"result":{"turn":{"id":"t-fork","status":"inProgress"}}}'
          echo '{"method":"item/agentMessage/delta","params":{"threadId":"#{@parent_id}","turnId":"t-p","itemId":"p1","delta":"PARENT"}}'
          echo '{"method":"item/agentMessage/delta","params":{"threadId":"#{fork_thread}","turnId":"t-fork","itemId":"m1","delta":"It covers"}}'
          echo '{"method":"item/completed","params":{"threadId":"#{fork_thread}","turnId":"t-fork","item":{"type":"agentMessage","id":"m1","text":"It covers the retry."}}}'
          echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"#{fork_thread}","turnId":"t-fork","tokenUsage":{"total":{"totalTokens":42},"last":{"totalTokens":42}}}}'
          echo '{"method":"turn/completed","params":{"threadId":"#{fork_thread}","turn":{"id":"t-fork","status":"completed"}}}' ;;
      esac
    done
    """)
  end

  def write_exe(path, script) do
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  def parent_state(session_file, session_dir, repo) do
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo)

    {:crypto.hash(:sha256, File.read!(session_file)), File.ls!(session_dir) |> Enum.sort(), status,
     File.read!(Path.join(repo, "lib.ex"))}
  end

  def recorded(dir, name), do: dir |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)

  # The stub writes the pid file after it starts; wait for it rather than for a fixed time.
  def recorded_pid(dir, name, tries \\ 100) do
    case File.read(Path.join(dir, name)) do
      {:ok, pid} when pid != "" -> String.trim(pid)
      _ when tries > 0 -> Process.sleep(20) && recorded_pid(dir, name, tries - 1)
    end
  end

  # SIGKILL is delivered asynchronously and an exited child stays a zombie until reaped,
  # so poll a bounded number of times.
  def gone?(pid, tries \\ 250) do
    dead =
      case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
        {_, status} when status != 0 -> true
        {stat, 0} -> String.starts_with?(String.trim(stat), "Z")
      end

    cond do
      dead -> true
      tries == 0 -> false
      true -> Process.sleep(20) && gone?(pid, tries - 1)
    end
  end

  def with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(vars)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
