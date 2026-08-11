defmodule Aiur.IssueDispositionHookTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @hook_path Path.join(@repo_root, ".claude/hooks/issue-disposition.py")
  @settings_path Path.join(@repo_root, ".claude/settings.json")

  test "repository settings run the disposition guard before Bash tools" do
    settings = @settings_path |> File.read!() |> Jason.decode!()

    assert [entry] = settings["hooks"]["PreToolUse"]
    assert entry["matcher"] == "Bash"
    assert [%{"type" => "command", "command" => command}] = entry["hooks"]
    assert command =~ "${CLAUDE_PROJECT_DIR}/.claude/hooks/issue-disposition.py"
  end

  test "an Executor issue create without a disposition is blocked before Bash runs" do
    assert {output, 2} = run_hook("gh issue create --title 'Something broke'")
    assert output =~ "no dispatch disposition"
  end

  test "only label flags prove a disposition" do
    assert {_output, 2} =
             run_hook("gh issue create --title 'mentions agent:todo but carries no label'")

    for command <- [
          "gh issue create --title x --label agent:todo",
          "gh issue create --title x --label=human:todo",
          "gh issue create --title x -lneeds-triage",
          "gh issue create --title x -l build-order",
          "gh issue create --title x --label bug,epic"
        ] do
      assert {"", 0} = run_hook(command), command
    end
  end

  test "marker, terminal, malformed, and unknown prefixed labels are not dispositions" do
    for label <- ~w(agent:watch agent:paused agent:done agent:not-a-state team:todo :todo Agent:todo) do
      assert {output, 2} = run_hook("gh issue create --title x --label #{label}"), label
      assert output =~ "no dispatch disposition", label
    end
  end

  test "gh root repository flags cannot bypass disposition validation" do
    for command <- [
          "gh -R owner/repo issue create --title x",
          "gh --repo=owner/repo issue create --title x",
          "gh issue --repo owner/repo create --title x"
        ] do
      assert {output, 2} = run_hook(command), command
      assert output =~ "no dispatch disposition", command
    end
  end

  test "the Executor hook honors the configured lifecycle prefix" do
    env = [{"AIUR_GITHUB_LABEL_PREFIX", "team"}]
    assert {"", 0} = run_hook("gh issue create --title x --label team:todo", env)

    assert {output, 2} = run_hook("gh issue create --title x --label agent:todo", env)
    assert output =~ "pass --label team:todo"
  end

  test "a later labelled command cannot disguise an earlier unlabelled create" do
    command = "gh issue create --title first\ngh issue create --title second --label agent:todo"

    assert {output, 2} = run_hook(command)
    assert output =~ "no dispatch disposition"
  end

  test "nested shells and command substitutions cannot bypass disposition validation" do
    for command <- [
          ~s(bash -lc "gh issue create --title x"),
          "result=$(gh issue create --title x)",
          "result=`gh issue create --title x`",
          "cat <(gh issue create --title x)"
        ] do
      assert {output, 2} = run_hook(command), command
      assert output =~ "no dispatch disposition", command
    end

    assert {"", 0} = run_hook(~s(bash -lc "gh issue create --title x --label agent:todo"))
    assert {"", 0} = run_hook("printf '%s' '$(gh issue create --title x)'")
  end

  test "env and command wrappers preserve the guarded executable boundary" do
    for command <- [
          "env -u GH_TOKEN gh issue create --title x",
          "env --unset=GH_TOKEN gh issue create --title x",
          "command -- gh issue create --title x",
          ~s(env -S "gh issue create --title x"),
          ~s(env -S"gh issue create --title x"),
          ~s(env --split-string="gh issue create --title x")
        ] do
      assert {output, 2} = run_hook(command), command
      assert output =~ "no dispatch disposition", command
    end
  end

  test "an exec wrapper inside a nested shell remains guarded" do
    assert {output, 2} = run_hook(~s(bash -c "exec gh issue create --title x"))
    assert output =~ "no dispatch disposition"
  end

  test "quoted command words and unrelated command flags are not issue creation" do
    for command <- [
          "printf '%s %s %s' gh issue create",
          "printf '%s' 'createIssue('",
          "gh api repos/owner/repo/issues && printf '%s' -f"
        ] do
      assert {"", 0} = run_hook(command), command
    end
  end

  test "direct REST, GraphQL, and HTTP client issue creation are blocked" do
    for command <- [
          "gh api repos/owner/repo/issues -f title=x -f 'labels[]=agent:todo'",
          "gh api graphql -f query='mutation { createIssue(input: {repositoryId: \"R\", title: \"x\"}) { issue { id } } }'",
          "curl -X POST https://api.github.com/repos/owner/repo/issues -d '{\"title\":\"x\"}'",
          "curl -XPOST https://api.github.com/repos/owner/repo/issues --data='{\"title\":\"x\"}'",
          "curl --request=POST https://api.github.com/repos/owner/repo/issues --json '{\"title\":\"x\"}'",
          "wget https://api.github.com/repos/owner/repo/issues --post-data='{\"title\":\"x\"}'",
          "http https://api.github.com/repos/owner/repo/issues title=x",
          "https POST https://api.github.com/repos/owner/repo/issues title=x",
          "http --auth user:pass POST https://api.github.com/repos/owner/repo/issues title=x",
          "https --verify=no POST https://api.github.com/repos/owner/repo/issues title=x"
        ] do
      assert {output, 2} = run_hook(command), command
      assert output =~ "use `gh issue create --label ...`", command
    end
  end

  test "non-creation Bash commands are unchanged" do
    for command <- [
          "gh issue list --state open",
          "gh api repos/owner/repo/issues",
          "command -v gh",
          "curl https://api.github.com/repos/owner/repo/issues",
          "curl -XGET https://api.github.com/repos/owner/repo/issues -d q=x",
          "wget https://api.github.com/repos/owner/repo/issues",
          "http https://api.github.com/repos/owner/repo/issues",
          "http GET https://api.github.com/repos/owner/repo/issues q=x",
          "http --auth user:pass GET https://api.github.com/repos/owner/repo/issues q=x",
          "https --verify=no GET https://api.github.com/repos/owner/repo/issues q=x",
          "http --auth POST https://api.github.com/repos/owner/repo/issues",
          "http --session POST https://api.github.com/repos/owner/repo/issues",
          "http --auth POST GET https://api.github.com/repos/owner/repo/issues q=x",
          "http https://api.github.com/repos/owner/repo/issues --auth=user:pass",
          "http https://api.github.com/repos/owner/repo/issues q==x",
          "mix test"
        ] do
      assert {"", 0} = run_hook(command), command
    end
  end

  defp run_hook(command, env \\ []) do
    python = System.find_executable("python3") || flunk("python3 is required")

    payload =
      Jason.encode!(%{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command}
      })

    System.cmd(
      "sh",
      ["-c", ~s(printf '%s' "$2" | "$1" "$3"), "sh", python, payload, @hook_path],
      env: env,
      stderr_to_stdout: true
    )
  end
end
