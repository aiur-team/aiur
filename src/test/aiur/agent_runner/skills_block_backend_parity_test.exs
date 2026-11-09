defmodule Aiur.AgentRunner.SkillsBlockBackendParityTest do
  @moduledoc """
  Every backend's real first request carries the ticket's mapped skills inlined
  (#7866). The prompt is built once by the shared turn path; these tests capture
  what each backend actually puts on the wire.

  Codex runs the whole `AgentRunner.run` path against a fake app-server. Claude
  and the OpenAI-compatible backend run their production `start_session` and
  `run_turn` with the first-turn prompt from `TurnLoop.build_turn_prompt/5`, the
  function the turn loop calls for turn 1.
  """

  use Aiur.TestSupport

  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.OpenAICompat.CodingAgent, as: CompatAgent

  @sentinel "ROLE SKILL SENTINEL 7866"
  @skill_md "---\nname: role-skill\ndescription: \"Role instructions.\"\n---\n\n#{@sentinel}\n"

  defp issue(id) do
    %Issue{
      id: "issue-#{id}",
      identifier: id,
      title: "Skills parity",
      description: "Skills: role-skill",
      state: "In Progress",
      url: "https://example.org/issues/#{id}",
      labels: []
    }
  end

  defp install_skill!(workspace) do
    dir = Path.join([workspace, ".claude", "skills", "role-skill"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), @skill_md)
  end

  defp assert_skills_inlined(text) do
    assert text =~ "### Mapped skills (load first)"
    assert text =~ "#### `role-skill` — mapped by override:Skills:"
    assert text =~ @sentinel
  end

  defp frames(path, method) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_leading(&1, "JSON:"))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"method" => ^method} = frame} -> [frame]
        _other -> []
      end
    end)
  end

  test "codex app-server: the first turn/start of a dispatched run inlines the mapped skill" do
    root = Aiur.TestSupport.tmp_root!("skills-parity-codex")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    codex = Path.join(root, "fake-codex")
    trace = Path.join(root, "codex.trace")
    File.mkdir_p!(root)
    skill_source = Path.join(root, "SKILL.md")
    File.write!(skill_source, @skill_md)

    File.write!(codex, """
    #!/bin/sh
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> #{trace}
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-skills"}}}' ;;
        *'"method":"turn/start"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"result":{"turn":{"id":"turn-1"}}}\\n' "$request_id"
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(root, "workspaces"),
      hook_after_create: "mkdir -p .claude/skills/role-skill && cp #{skill_source} .claude/skills/role-skill/SKILL.md",
      codex_command: "#{codex} app-server",
      max_turns: 1
    )

    issue = issue("MT-7866")
    AgentRunner.run(issue, self(), issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)

    assert [first | _rest] = frames(trace, "turn/start")
    assert_skills_inlined(first |> get_in(["params", "input"]) |> Enum.map_join("\n", &Map.get(&1, "text", "")))
  end

  test "claude app-server: the first turn/start carries the inlined mapped skill" do
    root = Aiur.TestSupport.tmp_root!("skills-parity-claude")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    install_skill!(workspace)
    trace = Path.join(root, "frames.jsonl")

    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    completed = ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"status":"completed"}}})

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command:
        "while IFS= read -r line; do echo \"$line\" >> #{trace}; case \"$line\" in " <>
          "*'\"initialize\"'*) echo '#{init}' ;; *'\"thread/start\"'*) echo '#{thread}' ;; " <>
          "*'\"turn/start\"'*) echo '#{turn}'; echo '#{completed}' ;; esac; done"
    )

    issue = issue("7866")
    prompt = TurnLoop.build_turn_prompt(issue, workspace, [], 1, nil)

    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    assert {:ok, %{result: :turn_completed}} = ClaudeAgent.run_turn(session, prompt, issue)
    ClaudeAgent.stop_session(session)

    assert [first | _rest] = frames(trace, "turn/start")
    assert_skills_inlined(first |> get_in(["params", "input"]) |> Enum.map_join("\n", &Map.get(&1, "text", "")))
  end

  test "openai-compatible: the first chat request carries the inlined mapped skill" do
    # The compat backend refuses a cwd outside the configured workspace root.
    workspace = Path.join(Aiur.Config.workspace_root(), "skills-parity-compat-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)
    File.mkdir_p!(workspace)
    install_skill!(workspace)
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         headers: %{},
         body: %{
           "id" => "req-1",
           "model" => "test-model",
           "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "done"}}],
           "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
         }
       }}
    end

    instance = %{
      base_url: "https://example.invalid/v1",
      api_key_env: "TEST_KEY",
      default_model: "test-model",
      transport: :chat_completions,
      quirks: %{}
    }

    issue = issue("7866")
    prompt = TurnLoop.build_turn_prompt(issue, workspace, [], 1, nil)

    assert {:ok, session} =
             CompatAgent.start_session(workspace,
               backend: "openrouter",
               instance: instance,
               api_key_fetcher: fn "TEST_KEY" -> "test-key" end,
               request_fun: request_fun
             )

    assert {:ok, %{result: :turn_completed}} = CompatAgent.run_turn(session, prompt, issue, [])
    CompatAgent.stop_session(session)

    assert_receive {:request, first}, 1_000
    user = Enum.find(first.json["messages"], &(&1["role"] == "user"))
    assert_skills_inlined(user["content"])
  end
end
