defmodule VoiceConverse.AgentForkTest do
  # Some tests change the BEAM's OS env, which every fork child inherits.
  use ExUnit.Case, async: false

  alias VoiceConverse.AgentFork
  alias VoiceConverse.AgentFork.{ClaudeCode, Handle}

  @fixtures Path.expand("../fixtures/agent_fork", __DIR__)
  @parent_id "0d6b2a9c-7e11-4c55-9e1f-3f2c1d7e8a4b"
  @fork_thread "fork-thread-0001"

  @claude_help """
  Usage: claude [options]
    -p, --print  --resume <id>  --fork-session  --no-session-persistence  --permission-mode <mode>
    --tools <tools...>  --disallowedTools <tools...>  --strict-mcp-config  --settings <file-or-json>
    --permission-prompts <target>
    --max-turns <n>  --input-format <format>  --output-format <format>  --include-partial-messages  --verbose
  """

  setup do
    root = Path.join(System.tmp_dir!(), "agent_fork_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "handle discovery" do
    test "reads the Claude Code session and config dir a Bash tool shell carries" do
      assert {:ok, %{harness: :claude_code, session_id: "3f2c1d7e-8a4b-4c55-9e1f-0d6b2a9c7e11"} = handle} =
               Handle.discover(fixture_env("claude_code_tool_shell.env"), "/work")

      assert handle.cwd == "/work"
      assert handle.config_dir == "/home/dev/.claude-work"
    end

    test "reads the Codex thread a shell tool command carries" do
      assert {:ok,
              %{harness: :codex, session_id: "019a4f2e-6c1d-7b30-a9e4-5f8d2c1b0a77", config_dir: "/home/dev/.codex"}} =
               Handle.discover(fixture_env("codex_tool_shell.env"), "/work")
    end

    test "has no handle outside an agent, and refuses to guess between two agents" do
      assert {:error, :no_handle} = Handle.discover(%{"PATH" => "/bin"}, "/work")

      both = Map.merge(fixture_env("claude_code_tool_shell.env"), fixture_env("codex_tool_shell.env"))
      assert {:error, :ambiguous_handle} = Handle.discover(both, "/work")
    end
  end

  describe "Claude Code native fork" do
    test "claude fork argv is read-only and unpersisted", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :answer)

      assert {:ok, ref} = AgentFork.fork(claude_handle(parent), "why did you drop the retry?", claude_executable: exe)
      assert_receive {:fork_answer, ^ref, "It hid the real error.", :native, usage}, 5_000
      assert is_integer(usage.first_token_ms)
      assert usage.tokens == %{"input_tokens" => 10, "output_tokens" => 5}

      assert recorded(ctx.root, "argv") == [
               "-p",
               "--resume",
               @parent_id,
               "--fork-session",
               "--no-session-persistence",
               "--permission-mode",
               "plan",
               "--tools",
               "Read,Grep,Glob",
               "--disallowedTools",
               "mcp__*",
               "--strict-mcp-config",
               "--settings",
               ~s({"disableAllHooks":true}),
               "--permission-prompts",
               "none",
               "--max-turns",
               "6",
               "--input-format",
               "stream-json",
               "--output-format",
               "stream-json",
               "--include-partial-messages",
               "--verbose"
             ]

      assert recorded(ctx.root, "cwd") == [parent.repo]

      [stdin] = recorded(ctx.root, "stdin")
      assert %{"type" => "user", "message" => %{"content" => [%{"text" => prompt}]}} = Jason.decode!(stdin)
      assert prompt =~ AgentFork.read_only_note()
      assert prompt =~ "why did you drop the retry?"
    end

    test "the child env has no GitHub token and no key the host loaded from .env", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :answer)

      with_env(
        %{
          "GITHUB_TOKEN" => "ghp_x",
          "GH_TOKEN" => "gho_x",
          "ANTHROPIC_API_KEY" => "sk-dotenv",
          "CLAUDECODE" => "1",
          "CLAUDE_CODE_ENTRYPOINT" => "cli",
          "CLAUDE_CODE_SESSION_ID" => @parent_id,
          "CODEX_THREAD_ID" => "019a4f2e-6c1d",
          "SHELL_KEPT" => "1"
        },
        fn ->
          {:ok, ref} =
            AgentFork.fork(claude_handle(parent), "q", claude_executable: exe, env_drop: ["ANTHROPIC_API_KEY"])

          assert_receive {:fork_answer, ^ref, _, :native, _}, 5_000
        end
      )

      env = ctx.root |> recorded("env") |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))
      refute Map.has_key?(env, "GITHUB_TOKEN")
      refute Map.has_key?(env, "GH_TOKEN")
      # A leaked API key would make claude bill it instead of the user's own login.
      refute Map.has_key?(env, "ANTHROPIC_API_KEY")
      # A nested claude that sees these takes itself for part of the parent session.
      for name <- ~w(CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID),
          do: refute(Map.has_key?(env, name), name)

      assert env["SHELL_KEPT"] == "1"
      assert env["CLAUDE_CONFIG_DIR"] == parent.config_dir
    end

    test "fork leaves the parent unchanged, even mid tool call", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :answer)
      before = parent_state(parent.transcript, parent.project_dir, parent.repo)

      {:ok, ref} = AgentFork.fork(claude_handle(parent), "what are you editing?", claude_executable: exe)
      assert_receive {:fork_answer, ^ref, _, :native, _}, 5_000

      # Same transcript bytes, no new session file in the project dir, same worktree status.
      assert parent_state(parent.transcript, parent.project_dir, parent.repo) == before
    end

    test "a CLI without every read-only flag is refused, not run with fewer limits", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :answer, String.replace(@claude_help, "--no-session-persistence", ""))

      assert {:error, :unsafe_cli} = AgentFork.fork(claude_handle(parent), "q", claude_executable: exe)
      refute File.exists?(Path.join(ctx.root, "argv"))
    end

    test "a session id that could parse as a flag is refused before anything runs", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :answer)

      for id <- ["--dangerously-skip-permissions", "", nil, "not-a-uuid"] do
        handle = %{claude_handle(parent) | session_id: id}
        assert {:error, :invalid_handle} = AgentFork.fork(handle, "q", claude_executable: exe)
      end

      codex = %{harness: :codex, session_id: "--config=x", cwd: parent.repo, config_dir: nil}
      assert {:error, :invalid_handle} = AgentFork.fork(codex, "q", codex_executable: exe)
      assert {:error, :invalid_handle} = Handle.discover(%{"CLAUDE_CODE_SESSION_ID" => "--resume"}, "/work")
      refute File.exists?(Path.join(ctx.root, "argv"))
    end

    test "a CLI whose --help hangs is refused within the probe deadline", ctx do
      parent = claude_parent(ctx.root)
      exe = write_exe(Path.join(ctx.root, "claude"), "#!/bin/sh\nsleep 300\n")

      assert {:error, :unsafe_cli} = AgentFork.fork(claude_handle(parent), "q", claude_executable: exe)
    end

    test "a second concurrent fork is busy, and the key frees once the first answers", ctx do
      parent = claude_parent(ctx.root)
      hang = claude_stub(ctx.root, parent, :hang)
      handle = claude_handle(parent)

      {:ok, first} = AgentFork.fork(handle, "q1", claude_executable: hang, lock_key: :voice_1, timeout_ms: 1_000)
      assert {:error, :fork_busy} = AgentFork.fork(handle, "q2", claude_executable: hang, lock_key: :voice_1)
      assert_receive {:fork_failed, ^first, :timeout}, 5_000

      answer = claude_stub(Path.join(ctx.root, "again"), parent, :answer)
      assert {:ok, second} = AgentFork.fork(handle, "q3", claude_executable: answer, lock_key: :voice_1)
      assert_receive {:fork_answer, ^second, _, :native, _}, 5_000
    end

    test "timeout kills the fork tree", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :hang)

      {:ok, ref} = AgentFork.fork(claude_handle(parent), "q", claude_executable: exe, timeout_ms: 300)
      assert_receive {:fork_failed, ^ref, :timeout}, 5_000

      for name <- ["pid", "grandchild"], do: assert(gone?(recorded_pid(ctx.root, name)), "#{name} survived")
    end

    test "the fork is killed when the process waiting for it exits", ctx do
      parent = claude_parent(ctx.root)
      exe = claude_stub(ctx.root, parent, :hang)
      waiter = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, _ref} = AgentFork.fork(claude_handle(parent), "q", claude_executable: exe, reply_to: waiter)
      grandchild = recorded_pid(ctx.root, "grandchild")
      Process.exit(waiter, :kill)

      assert gone?(grandchild)
    end
  end

  describe "Codex native fork" do
    test "codex fork params are ephemeral read-only", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @fork_thread)

      assert {:ok, ref} = AgentFork.fork(codex_handle(parent), "why that test?", codex_executable: exe)
      assert_receive {:fork_answer, ^ref, "It covers the retry.", :native, usage}, 5_000
      assert is_integer(usage.first_token_ms)
      assert usage.tokens["total"]["totalTokens"] == 42

      assert recorded(ctx.root, "argv") == ["app-server", "--disable", "hooks", "-c", "notify=[]"]

      rpc = ctx.root |> recorded("rpc") |> Enum.map(&Jason.decode!/1)
      # Nothing else (no thread/resume, no turn on the parent) is ever sent.
      assert Enum.map(rpc, & &1["method"]) == ["initialize", "initialized", "thread/fork", "turn/start"]

      fork = Enum.find(rpc, &(&1["method"] == "thread/fork"))["params"]

      assert fork == %{
               "threadId" => @parent_id,
               "ephemeral" => true,
               "excludeTurns" => true,
               "sandbox" => "read-only",
               "approvalPolicy" => "never",
               "cwd" => parent.repo
             }

      # An in-progress lastTurnId is rejected; omitting it is the safe way to fork a busy parent.
      refute Map.has_key?(fork, "lastTurnId")

      turn = Enum.find(rpc, &(&1["method"] == "turn/start"))["params"]
      assert turn["threadId"] == @fork_thread
      assert turn["approvalPolicy"] == "never"
      assert turn["sandboxPolicy"] == %{"type" => "readOnly", "networkAccess" => false}
      assert [%{"type" => "text", "text" => prompt}] = turn["input"]
      assert prompt =~ AgentFork.read_only_note()
    end

    test "fork leaves the Codex parent unchanged", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @fork_thread)
      before = parent_state(parent.rollout, parent.sessions_dir, parent.repo)

      {:ok, ref} = AgentFork.fork(codex_handle(parent), "q", codex_executable: exe)
      assert_receive {:fork_answer, ^ref, _, :native, _}, 5_000

      assert parent_state(parent.rollout, parent.sessions_dir, parent.repo) == before
    end

    test "a fork that comes back as the parent thread is refused before any turn", ctx do
      parent = codex_parent(ctx.root)
      exe = codex_stub(ctx.root, parent, @parent_id)

      {:ok, ref} = AgentFork.fork(codex_handle(parent), "q", codex_executable: exe)
      assert_receive {:fork_failed, ^ref, :fork_not_isolated}, 5_000
      refute Enum.any?(recorded(ctx.root, "rpc"), &(&1 =~ "turn/start"))
    end
  end

  describe "replay fallback" do
    test "a replay answer says it came from a summary" do
      test_pid = self()

      model = fn prompt ->
        send(test_pid, {:prompt, prompt})
        {:ok, "From the briefing: flaky upstream.", %{tokens: 7}}
      end

      handle = %{harness: :other, session_id: nil, cwd: "/work", config_dir: nil}
      opts = [replay_model: model, briefing: "Agent is fixing the retry loop."]

      assert AgentFork.capability(handle, opts) == :replay
      assert {:ok, ref} = AgentFork.fork(handle, "why?", opts)
      assert_receive {:fork_answer, ^ref, "From the briefing: flaky upstream.", :replay, %{tokens: 7}}, 5_000
      assert_receive {:prompt, prompt}
      assert prompt =~ AgentFork.read_only_note()
      assert prompt =~ "Agent is fixing the retry loop."
      assert prompt =~ "Question: why?"
    end

    test "OpenCode replays until its fork is shown to be read-only" do
      handle = %{harness: :opencode, session_id: "ses_1", cwd: "/work", config_dir: nil}

      assert AgentFork.capability(handle, replay_model: fn _ -> {:ok, "a"} end) == :replay
      assert {:ok, ref} = AgentFork.fork(handle, "q", replay_model: fn _ -> {:ok, "a"} end)
      assert_receive {:fork_answer, ^ref, "a", :replay, _}, 5_000
    end

    test "with no replay model there is no fork and nothing starts" do
      handle = %{harness: :other, session_id: nil, cwd: "/work", config_dir: nil}

      assert AgentFork.capability(handle) == :none
      assert {:error, :none} = AgentFork.fork(handle, "q")
      refute_received {:fork_answer, _, _, _, _}
    end

    test "a crashing replay model fails the fork instead of losing the answer" do
      handle = %{harness: :other, session_id: nil, cwd: "/work", config_dir: nil}

      {:ok, ref} = AgentFork.fork(handle, "q", replay_model: fn _ -> raise "model down" end)
      assert_receive {:fork_failed, ^ref, {:crashed, "model down"}}, 5_000
    end
  end

  test "argv uses the caller's max_turns" do
    assert ["--max-turns", "2"] = ClaudeCode.argv("id", 2) |> Enum.drop_while(&(&1 != "--max-turns")) |> Enum.take(2)
  end

  # ---------------------------------------------------------------- helpers

  defp fixture_env(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))
  end

  # A mid-edit worktree: one committed file with an uncommitted change.
  defp git_repo(root) do
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

  defp claude_parent(root) do
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

  defp claude_handle(parent),
    do: %{harness: :claude_code, session_id: @parent_id, cwd: parent.repo, config_dir: parent.config_dir}

  # A stub `claude` that records argv, env, cwd and stdin. It misbehaves the way the real CLI
  # would without each read-only flag: without --fork-session it appends to the parent, without
  # --no-session-persistence it writes a session file, without plan mode or with hooks enabled it
  # edits the worktree (a SessionStart hook is arbitrary shell).
  defp claude_stub(dir, parent, behaviour, help \\ @claude_help) do
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

  defp codex_parent(root) do
    codex_home = Path.join(root, "codex-home")
    sessions_dir = Path.join(codex_home, "sessions")
    File.mkdir_p!(sessions_dir)
    rollout = Path.join(sessions_dir, "rollout-#{@parent_id}.jsonl")
    File.write!(rollout, ~s({"type":"turn_context"}\n))
    %{codex_home: codex_home, sessions_dir: sessions_dir, rollout: rollout, repo: git_repo(root)}
  end

  defp codex_handle(parent),
    do: %{harness: :codex, session_id: @parent_id, cwd: parent.repo, config_dir: parent.codex_home}

  # A stub `codex app-server` that records every JSON-RPC line. It misbehaves like the real
  # server would without each guard: a non-ephemeral fork writes a rollout file, a turn on the
  # parent appends to the parent's rollout, a turn without the read-only sandbox, or a server with
  # hooks or `notify` enabled, edits the worktree.
  defp codex_stub(dir, parent, fork_thread) do
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

  defp write_exe(path, script) do
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp parent_state(session_file, session_dir, repo) do
    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo)

    {:crypto.hash(:sha256, File.read!(session_file)), File.ls!(session_dir) |> Enum.sort(), status,
     File.read!(Path.join(repo, "lib.ex"))}
  end

  defp recorded(dir, name), do: dir |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)

  # The stub writes the pid file after it starts; wait for it rather than for a fixed time.
  defp recorded_pid(dir, name, tries \\ 100) do
    case File.read(Path.join(dir, name)) do
      {:ok, pid} when pid != "" -> String.trim(pid)
      _ when tries > 0 -> Process.sleep(20) && recorded_pid(dir, name, tries - 1)
    end
  end

  # SIGKILL is delivered asynchronously and an exited child stays a zombie until reaped,
  # so poll a bounded number of times.
  defp gone?(pid, tries \\ 250) do
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

  defp with_env(vars, fun) do
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
