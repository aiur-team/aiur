defmodule Aiur.AgentGitHubGuard.ForkRefusalTest do
  use Aiur.AgentGitHubGuardCase, async: true

  @expected "owner/repo"

  defp repo_with_remote(context, url) do
    repo = context.workspace
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", "-b", "main", repo], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", repo, "remote", "add", "origin", url], stderr_to_stdout: true)
    repo
  end

  test "git push to a fork named by pushRemote is refused with the expected repository", context do
    repo = repo_with_remote(context, "https://github.com/owner/repo.git")
    assert {_, 0} = System.cmd(real_git(), ["-C", repo, "remote", "add", "fork", "https://github.com/agent-user/repo.git"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", repo, "config", "branch.main.pushRemote", "fork"], stderr_to_stdout: true)

    assert {output, 64} = run_git_guard(context, ["push", "--dry-run"], AIUR_GITHUB_REPO: @expected)
    assert output =~ "refusing push to agent-user/repo"
    assert output =~ "only to owner/repo"
    assert output =~ "needs push access"
  end

  test "git push to the configured repository is not refused", context do
    repo_with_remote(context, "https://github.com/Owner/Repo.git")
    # Stands in for real git so an allowed push never reaches GitHub.
    fake = Path.join(context.workspace, "fake-git")
    File.write!(fake, "#!/bin/sh\nfor a in \"$@\"; do [ \"$a\" = push ] && { echo PUSHED; exit 0; }; done\nexec #{real_git()} \"$@\"\n")
    File.chmod!(fake, 0o755)

    # The merge-queue push guard calls the installed gh; answer it locally so the test never reaches GitHub.
    gh = Path.join(Path.dirname(context.git_wrapper), "gh")
    File.write!(gh, "#!/bin/sh\ncase \"$*\" in *graphql*) echo 'false MERGEABLE APPROVED' ;; *issues/*) echo 'priority:2 agent:in-progress' | tr ' ' '\\n' ;; *) exit 1 ;; esac\n")
    File.chmod!(gh, 0o755)

    env = [{"AIUR_REAL_GIT", fake}, {"AIUR_AGENT_WORKSPACE", context.workspace}, {"AIUR_GITHUB_REPO", @expected}]
    assert {"PUSHED\n", 0} = System.cmd(context.git_wrapper, ["push", "origin", "HEAD"], cd: context.workspace, env: env, stderr_to_stdout: true)
  end

  test "gh repo fork and a fork pr head are refused; the tracker owner head is not", context do
    for args <- [["repo", "fork"], ["pr", "create", "--head", "agent-user:branch"], ["pr", "create", "-H", "agent-user:b"], ["pr", "create", "--head=agent-user:b"]] do
      assert {output, 64} = run_guard(context, args, AIUR_GITHUB_REPO: @expected)
      assert output =~ "never on a fork"
      assert output =~ "owner/repo"
      assert output =~ "needs push access"
    end

    {output, _} = run_guard(context, ["pr", "create", "--head", "owner:branch"], AIUR_GITHUB_REPO: @expected)
    refute output =~ "never on a fork"
  end
end
