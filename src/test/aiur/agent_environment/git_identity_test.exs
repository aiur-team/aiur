defmodule Aiur.AgentEnvironment.GitIdentityTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment
  alias Aiur.AgentEnvironment.GitIdentity
  alias Aiur.Config.Schema
  alias Aiur.Opencode.Server
  alias Aiur.Workspace.{AttributionGuard, Provisioner}

  @identity {"Apple Kid", "its.applekid@gmail.com"}
  @git_names ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL)

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-git-identity-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    home = Path.join(root, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(home, "git"))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    # The operator's global identity, in both places git reads it from.
    operator = "[user]\n\tname = Operator Person\n\temail = operator@example.com\n"
    File.write!(Path.join(home, ".gitconfig"), operator)
    File.write!(Path.join(home, "git/config"), operator)

    {_out, 0} = System.cmd("git", ["init", "-q", workspace], stderr_to_stdout: true)
    %{workspace: workspace, home: home}
  end

  test "a provisioned worker commits as the configured identity and cannot add AI attribution", %{
    workspace: workspace,
    home: home
  } do
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    env =
      for {name, value} <- AgentEnvironment.workspace_env(workspace, git_identity: @identity),
          to_string(name) in @git_names do
        {to_string(name), to_string(value)}
      end

    assert Enum.sort(Keyword.keys(Enum.map(env, fn {k, v} -> {String.to_atom(k), v} end))) ==
             Enum.sort(Enum.map(@git_names, &String.to_atom/1))

    commit = fn message ->
      git(workspace, home, env, ["commit", "--allow-empty", "-m", message])
    end

    assert {_out, 0} = commit.("Fix the thing")

    assert {"Apple Kid <its.applekid@gmail.com>|Apple Kid <its.applekid@gmail.com>\n", 0} =
             git(workspace, home, env, ["log", "-1", "--format=%an <%ae>|%cn <%ce>"])

    assert {_out, 0} =
             commit.(
               "Add more\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nCo-authored-by: its-everdred <kevinweaver2@gmail.com>\nGenerated with Claude Code\nhttps://claude.ai/code/session_abc\nSee src/lib/aiur/session/store.ex\nGenerated with protoc"
             )

    assert {message, 0} = git(workspace, home, env, ["show", "-s", "--format=%B", "HEAD"])
    refute message =~ "Claude"
    refute message =~ "anthropic.com"
    refute message =~ "Generated with Claude"
    refute message =~ "claude.ai"
    assert message =~ "Co-authored-by: its-everdred <kevinweaver2@gmail.com>"
    assert message =~ "See src/lib/aiur/session/store.ex"
    assert message =~ "Generated with protoc"
    assert {"2\n", 0} = git(workspace, home, env, ["rev-list", "--count", "HEAD"])

    settings =
      workspace |> Path.join(".claude/settings.local.json") |> File.read!() |> Jason.decode!()

    assert settings["includeCoAuthoredBy"] == false
    assert settings["attribution"] == %{"commit" => "", "pr" => ""}
    # The injected settings file must never show up as agent work.
    assert {"", 0} =
             git(workspace, home, env, [
               "status",
               "--porcelain",
               "--",
               ".claude/settings.local.json"
             ])
  end

  test "pre-push names and refuses a commit that still carries an AI trailer", %{
    workspace: workspace,
    home: home
  } do
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)
    git(workspace, home, [], ["config", "user.name", "Test User"])
    git(workspace, home, [], ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "tracked"), "content\n")
    git(workspace, home, [], ["add", "tracked"])

    git(workspace, home, [], [
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-m",
      "unsafe commit\n\nCo-authored-by: Claude <noreply@anthropic.com>"
    ])

    sha = String.trim(elem(git(workspace, home, [], ["rev-parse", "HEAD"]), 0))

    push_input =
      "refs/heads/main #{sha} refs/heads/main 0000000000000000000000000000000000000000\n"

    {output, status} =
      System.cmd("sh", ["-c", "cd \"$1\" && printf '%s' \"$2\" | .git/hooks/pre-push", "sh", workspace, push_input], stderr_to_stdout: true)

    assert status == 1, output
    assert output =~ sha
    assert output =~ "unsafe commit"
  end

  test "the shell launch prefix exports the identity for backends without an env option" do
    prefix =
      AgentEnvironment.workspace_env_export_prefix("/work/aiur/4068",
        base_branch: "main",
        git_identity: {"O'Brien Bot", "bot@example.com"}
      )

    assert prefix =~ "export GIT_AUTHOR_NAME='O'\"'\"'Brien Bot'\n"
    assert prefix =~ "export GIT_COMMITTER_EMAIL='bot@example.com'\n"
  end

  test "no configured identity commits as the neutral agent, never the operator", %{
    workspace: workspace,
    home: home
  } do
    env = GitIdentity.env(git_identity: nil)

    assert GitIdentity.resolve(%{name: nil, email: nil}, nil) ==
             {"Aiur Agent", "aiur-agent@users.noreply.github.com"}

    assert {_out, 0} =
             git(workspace, home, env, ["commit", "--allow-empty", "-m", "Fix the thing"])

    neutral = "Aiur Agent <aiur-agent@users.noreply.github.com>"

    assert {"#{neutral}|#{neutral}\n", 0} ==
             git(workspace, home, env, ["log", "-1", "--format=%an <%ae>|%cn <%ce>"])
  end

  test "an opencode serve launches with the identity" do
    launch_env = Server.launch_env("/workspace", git_identity: @identity)

    for name <- ~w(GIT_AUTHOR_NAME GIT_COMMITTER_NAME),
        do: assert({String.to_charlist(name), ~c"Apple Kid"} in launch_env)

    for name <- ~w(GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL),
        do: assert({String.to_charlist(name), ~c"its.applekid@gmail.com"} in launch_env)
  end

  test "unset fields fall back to the bot account login" do
    assert GitIdentity.resolve(%{name: nil, email: " "}, "its-applekid") ==
             {"its-applekid", "its-applekid@users.noreply.github.com"}

    assert GitIdentity.resolve(%{name: "Apple Kid", email: nil}, "its-applekid") ==
             {"Apple Kid", "its-applekid@users.noreply.github.com"}

    assert GitIdentity.resolve(%{name: "Apple Kid", email: "kid@example.com"}, nil) ==
             {"Apple Kid", "kid@example.com"}
  end

  test "install chains repository-owned Git hooks and leaves tracked settings alone", %{
    workspace: workspace,
    home: home
  } do
    hook = Path.join(workspace, ".git/hooks/commit-msg")
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\necho called > commit-hook-called\n")
    File.chmod!(hook, 0o755)
    pre_push = Path.join(workspace, ".git/hooks/pre-push")
    File.write!(pre_push, "#!/bin/sh\ncat > pre-push-input\n")
    File.chmod!(pre_push, 0o755)
    File.mkdir_p!(Path.join(workspace, ".claude"))
    File.write!(Path.join(workspace, ".claude/settings.local.json"), "{\"model\": \"x\"}\n")
    {_out, 0} = git(workspace, home, [], ["add", "-f", ".claude/settings.local.json"])

    assert :ok = AttributionGuard.install(workspace)

    assert File.read!(hook <> ".aiur-original") == "#!/bin/sh\necho called > commit-hook-called\n"
    assert File.read!(pre_push <> ".aiur-original") == "#!/bin/sh\ncat > pre-push-input\n"

    message_path = Path.join(workspace, "message")
    File.write!(message_path, "subject\n\nCo-authored-by: Claude <noreply@anthropic.com>\n")
    {output, 0} = System.cmd(hook, [message_path], cd: workspace, stderr_to_stdout: true)
    assert output == ""
    refute File.read!(message_path) =~ "Claude"
    assert File.exists?(Path.join(workspace, "commit-hook-called"))

    sha = String.trim(elem(git(workspace, home, [], ["rev-parse", "HEAD"]), 0))
    push_input = "refs/heads/main #{sha} refs/heads/main 0000000000000000000000000000000000000000\n"
    {output, 0} = System.cmd("sh", ["-c", "printf '%s' \"$1\" | .git/hooks/pre-push", "sh", push_input], cd: workspace, stderr_to_stdout: true)
    assert output == ""
    assert File.read!(Path.join(workspace, "pre-push-input")) == push_input

    assert File.read!(Path.join(workspace, ".claude/settings.local.json")) ==
             "{\"model\": \"x\"}\n"
  end

  test "agent.git_identity parses and rejects values unsafe for an environment variable" do
    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{
                 "git_identity" => %{"name" => "Apple Kid", "email" => "its.applekid@gmail.com"}
               }
             })

    assert %{name: "Apple Kid", email: "its.applekid@gmail.com"} = settings.agent.git_identity

    assert {:ok, %{agent: %{git_identity: %{name: nil, email: nil}}}} = Schema.parse(%{})

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{"agent" => %{"git_identity" => %{"name" => "Evil\nName"}}})

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{"agent" => %{"git_identity" => %{"email" => "not-an-email"}}})
  end

  defp git(workspace, home, env, args) do
    isolation =
      [{"HOME", home}, {"XDG_CONFIG_HOME", home}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++
        Enum.map(@git_names, &{&1, nil})

    System.cmd("git", ["-C", workspace | args], env: isolation ++ env, stderr_to_stdout: true)
  end
end
