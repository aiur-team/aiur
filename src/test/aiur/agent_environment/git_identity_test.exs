defmodule Aiur.AgentEnvironment.GitIdentityTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment
  alias Aiur.AgentEnvironment.GitIdentity
  alias Aiur.Config.Schema
  alias Aiur.Workspace.Provisioner

  @identity {"Apple Kid", "its.applekid@gmail.com"}
  @git_names ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL)

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-git-identity-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    home = Path.join(root, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(home, "git"))
    on_exit(fn -> File.rm_rf!(root) end)

    # The operator's global identity, in both places git reads it from.
    operator = "[user]\n\tname = Operator Person\n\temail = operator@example.com\n"
    File.write!(Path.join(home, ".gitconfig"), operator)
    File.write!(Path.join(home, "git/config"), operator)

    {_out, 0} = System.cmd("git", ["init", "-q", workspace], stderr_to_stdout: true)
    %{workspace: workspace, home: home}
  end

  test "a provisioned worker commits as the configured identity and cannot add AI attribution", %{workspace: workspace, home: home} do
    assert :ok = Provisioner.maybe_install_agent_support(workspace, nil)

    env =
      for {name, value} <- AgentEnvironment.workspace_env(workspace, git_identity: @identity), to_string(name) in @git_names do
        {to_string(name), to_string(value)}
      end

    assert Enum.sort(Keyword.keys(Enum.map(env, fn {k, v} -> {String.to_atom(k), v} end))) == Enum.sort(Enum.map(@git_names, &String.to_atom/1))
    commit = fn message -> git(workspace, home, env, ["commit", "--allow-empty", "-m", message]) end

    assert {_out, 0} = commit.("Fix the thing")
    assert {"Apple Kid <its.applekid@gmail.com>|Apple Kid <its.applekid@gmail.com>\n", 0} = git(workspace, home, env, ["log", "-1", "--format=%an <%ae>|%cn <%ce>"])

    assert {out, 1} = commit.("Add more\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
    assert out =~ "AI attribution"
    assert {_out, 1} = commit.("Add more\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)")
    assert {_out, 0} = commit.("Add more\n\nCo-authored-by: its-everdred <kevinweaver2@gmail.com>")
    assert {"2\n", 0} = git(workspace, home, env, ["rev-list", "--count", "HEAD"])

    settings = workspace |> Path.join(".claude/settings.local.json") |> File.read!() |> Jason.decode!()
    assert settings["includeCoAuthoredBy"] == false
    assert settings["attribution"] == %{"commit" => "", "pr" => ""}
    # The injected settings file must never show up as agent work.
    assert {"", 0} = git(workspace, home, env, ["status", "--porcelain", "--", ".claude/settings.local.json"])
  end

  test "the shell launch prefix exports the identity for backends without an env option" do
    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/4068", base_branch: "main", git_identity: {"O'Brien Bot", "bot@example.com"})

    assert prefix =~ "export GIT_AUTHOR_NAME='O'\"'\"'Brien Bot'\n"
    assert prefix =~ "export GIT_COMMITTER_EMAIL='bot@example.com'\n"
  end

  test "no configured identity exports nothing, leaving git's own identity in place" do
    assert GitIdentity.env(git_identity: {nil, nil}) == []
    refute AgentEnvironment.workspace_env_export_prefix("/work/aiur/4068", base_branch: "main", git_identity: nil) =~ "GIT_AUTHOR"
  end

  test "unset fields fall back to the bot account login" do
    assert GitIdentity.resolve(%{name: nil, email: " "}, "its-applekid") == {"its-applekid", "its-applekid@users.noreply.github.com"}
    assert GitIdentity.resolve(%{name: "Apple Kid", email: nil}, "its-applekid") == {"Apple Kid", "its-applekid@users.noreply.github.com"}
    assert GitIdentity.resolve(%{name: "Apple Kid", email: "kid@example.com"}, nil) == {"Apple Kid", "kid@example.com"}
    assert GitIdentity.resolve(%{name: nil, email: nil}, nil) == {nil, nil}
  end

  test "install leaves a repository-owned commit-msg hook and tracked settings alone", %{workspace: workspace, home: home} do
    hook = Path.join(workspace, ".git/hooks/commit-msg")
    File.mkdir_p!(Path.dirname(hook))
    File.write!(hook, "#!/bin/sh\nexit 0\n")
    File.mkdir_p!(Path.join(workspace, ".claude"))
    File.write!(Path.join(workspace, ".claude/settings.local.json"), "{\"model\": \"x\"}\n")
    {_out, 0} = git(workspace, home, [], ["add", "-f", ".claude/settings.local.json"])

    assert :ok = Aiur.Workspace.AttributionGuard.install(workspace)

    assert File.read!(hook) == "#!/bin/sh\nexit 0\n"
    assert File.read!(Path.join(workspace, ".claude/settings.local.json")) == "{\"model\": \"x\"}\n"
  end

  test "agent.git_identity parses and rejects values unsafe for an environment variable" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"git_identity" => %{"name" => "Apple Kid", "email" => "its.applekid@gmail.com"}}})
    assert %{name: "Apple Kid", email: "its.applekid@gmail.com"} = settings.agent.git_identity

    assert {:ok, %{agent: %{git_identity: %{name: nil, email: nil}}}} = Schema.parse(%{})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"git_identity" => %{"name" => "Evil\nName"}}})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"git_identity" => %{"email" => "not-an-email"}}})
  end

  defp git(workspace, home, env, args) do
    isolation = [{"HOME", home}, {"XDG_CONFIG_HOME", home}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++ Enum.map(@git_names, &{&1, nil})
    System.cmd("git", ["-C", workspace | args], env: isolation ++ env, stderr_to_stdout: true)
  end
end
