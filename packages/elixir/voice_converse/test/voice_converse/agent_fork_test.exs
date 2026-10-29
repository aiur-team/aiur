defmodule VoiceConverse.AgentForkTest do
  # Some tests change the BEAM's OS env, which every fork child inherits.
  use ExUnit.Case, async: false

  alias VoiceConverse.AgentFork
  import VoiceConverse.AgentForkStubs

  alias VoiceConverse.AgentFork.{ClaudeCode, Handle}
  alias VoiceConverse.AgentForkStubs

  @fixtures Path.expand("../fixtures/agent_fork", __DIR__)
  @parent_id AgentForkStubs.parent_id()

  setup do
    %{root: tmp_root()}
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
      exe = claude_stub(ctx.root, parent, :answer, String.replace(claude_help(), "--no-session-persistence", ""))

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
end
