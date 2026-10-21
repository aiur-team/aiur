defmodule Aiur.AgentGitHubGuard.InstallAndTokenTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "installs the companion host-budget broker alongside the gh wrapper", context do
    assert File.regular?(AgentGitHubGuard.budget_broker_path(context.workspace))
    assert File.stat!(AgentGitHubGuard.budget_broker_path(context.workspace)).mode |> Bitwise.band(0o111) != 0

    metrics_path = Path.join(AgentGitHubGuard.bin_dir(context.workspace), "github_budget_metrics.py")
    assert File.regular?(metrics_path)
    assert File.read!(metrics_path) =~ "def receive_requests"
  end

  test "a re-install replaces a stale workspace broker and logs the refresh", context do
    installed = AgentGitHubGuard.budget_broker_path(context.workspace)

    # The setup install is current; make the workspace's copy stale (a broker
    # embedded under an older daemon release) before re-installing.
    File.write!(installed, "#!/usr/bin/env python3\nraise SystemExit('stale')\n")
    File.chmod!(installed, 0o755)

    log =
      capture_log(fn ->
        assert :ok = AgentGitHubGuard.install(context.workspace)
      end)

    # The one-line evidence the module offers that agent-side 304 reconciliation
    # was restored, now under test rather than untested observability (#2307
    # review).
    assert log =~ "refreshing stale agent budget broker"
    refute File.read!(installed) =~ "SystemExit('stale')"
  end

  # #2356: the guard's credential file sits in the shared budget root so every
  # workspace's wrapper resolves the same host credential without a token in
  # any environment.
  test "the guard credential file lives in the shared budget root", _context do
    assert AgentGitHubGuard.agent_token_path() == Path.join(Budget.state_dir(), "agent-token")
  end

  test "ensure_agent_token_file writes the credential at mode 0600", context do
    token_file = Path.join(context.state_path, "agent-token")

    assert :ok = AgentGitHubGuard.ensure_agent_token_file(token: "bot-pat", path: token_file)

    assert File.read!(token_file) == "bot-pat\n"
    assert Bitwise.band(File.stat!(token_file).mode, 0o077) == 0
  end

  test "ensure_agent_token_file removes a stale file when no credential is available", context do
    token_file = Path.join(context.state_path, "agent-token")
    File.mkdir_p!(context.state_path)
    File.write!(token_file, "stale-token\n")

    assert :no_credential = AgentGitHubGuard.ensure_agent_token_file(token: :none, path: token_file)
    refute File.exists?(token_file)
  end

  test "remote install writes the guard credential file for SSH workers", _context do
    script =
      AgentGitHubGuard.remote_install_script("/work/aiur/remote",
        token: "remote-bot-pat",
        remote_host: "worker-1"
      )

    assert script =~ "agent-token"
    assert script =~ "remote-bot-pat"
    assert script =~ "chmod 600"

    script =
      AgentGitHubGuard.remote_install_script("/work/aiur/remote",
        token: :none,
        remote_host: "worker-1"
      )

    assert script =~ "rm -f \"$HOME/.aiur/github-budget/agent-token\""
    refute script =~ "remote-bot-pat"
  end

  # #2478 — no fleet agent could push because the shared credential file was
  # deleted seconds after every restore. Two defects compounded, and this pins
  # both.
  #
  # `Keyword.fetch(opts, :token)` returned `{:ok, nil}` for an explicit
  # `token: nil`, so the `GITHUB_TOKEN` fallback was skipped and `nil` reached
  # the no-credential branch — a daemon that provably held the token still
  # resolved "no credential". That branch then emitted an unconditional
  # `rm -f "$HOME/.aiur/github-budget/agent-token"`, and `$HOME` is the
  # operator's own home whenever this script is generated or run locally.
  test "an explicit nil token falls back to the environment and writes rather than deletes" do
    env = fn
      "GITHUB_TOKEN" -> "env-bot-pat"
      _other -> nil
    end

    script =
      AgentGitHubGuard.remote_install_script("/work/aiur/remote",
        token: nil,
        remote_host: "worker-1",
        env_reader: env
      )

    assert script =~ "env-bot-pat"
    assert script =~ "chmod 600 \"$HOME/.aiur/github-budget/agent-token\""
    refute script =~ "rm -f \"$HOME/.aiur/github-budget/agent-token\""
  end

  # The destructive cleanup is only correct on a host the daemon is installing
  # onto over SSH. Generated without a remote host — the installer tests, any
  # local execution — it must never delete the shared operator-owned path.
  test "a local install never emits the host credential deletion" do
    script =
      AgentGitHubGuard.remote_install_script("/work/aiur/remote",
        token: nil,
        env_reader: fn _name -> nil end
      )

    refute script =~ "rm -f \"$HOME/.aiur/github-budget/agent-token\""
  end

  # The boot path (`Aiur.start/2`) calls this with no options. Under a scrubbed
  # environment — which #2356 makes the normal case for anything an agent runs,
  # including `mix test` — it must not delete the credential the real daemon
  # wrote. Only an explicit `token: :none` may remove it.
  test "an unresolvable credential leaves an existing file in place", context do
    token_file = Path.join(context.state_path, "agent-token")
    File.mkdir_p!(context.state_path)
    File.write!(token_file, "live-bot-pat\n")

    assert :no_credential =
             AgentGitHubGuard.ensure_agent_token_file(
               path: token_file,
               env_reader: fn _name -> nil end
             )

    assert File.read!(token_file) == "live-bot-pat\n"
  end

  test "ensure_agent_token_file treats an explicit nil token as not supplied", context do
    token_file = Path.join(context.state_path, "agent-token")
    File.mkdir_p!(context.state_path)

    env = fn
      "GITHUB_TOKEN" -> "env-bot-pat"
      _other -> nil
    end

    assert :ok =
             AgentGitHubGuard.ensure_agent_token_file(
               token: nil,
               path: token_file,
               env_reader: env
             )

    assert File.read!(token_file) == "env-bot-pat\n"
  end

  test "keeps the Executor wrapper outside the budget state directory" do
    refute String.starts_with?(AgentGitHubGuard.host_bin_dir(), Budget.state_dir())
  end

  # ---------------------------------------------------------------------------
  # Agents cannot approve or merge (the human merge gate)
  #
  # These test the documented bypass, not the existence of a wrapper. The real
  # attack is `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve`: with the
  # tokens gone, `gh` used to fall back to the operator's keyring account, which
  # is the sole branch-protection bypass actor. Each case therefore asserts that
  # the real `gh` was never reached at all.
  # ---------------------------------------------------------------------------

  test "provisions an agent-private, empty gh config dir", context do
    directory = AgentGitHubGuard.gh_config_dir(context.workspace)

    assert File.dir?(directory)
    assert File.ls!(directory) == []
    assert String.starts_with?(directory, context.workspace)
  end

  test "refuses a pull-request merge from an agent workspace", context do
    assert {output, 77} = run_guard(context, ["pr", "merge", "1670", "--squash"])

    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)
  end

  test "refuses an approval even when the agent strips both token variables", context do
    assert {output, 77} =
             run_agent_guard(
               context,
               ["pr", "review", "1670", "--approve"],
               Enum.reject(guard_env(context), fn {name, _value} -> name in ["GITHUB_TOKEN", "GH_TOKEN"] end)
             )

    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)
  end

  test "refuses a merge even when the agent clears the workspace marker", context do
    # Agent context is decided by where the wrapper is installed, so `$0` — not
    # an environment variable an agent can unset — carries the decision.
    assert {_output, 77} =
             run_agent_guard(
               context,
               ["pr", "merge", "1670"],
               Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end)
             )

    refute File.exists?(context.calls)
  end

  test "refuses the REST and GraphQL forms of approve and merge", context do
    assert {_output, 77} = run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/pulls/7/merge"])
    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/pulls/7/reviews", "-f", "event=APPROVE"])
    assert {_output, 77} = run_guard(context, ["api", "repos/owner/repo/pulls/7/reviews", "-f", "event=APPROVE"])

    assert {_output, 77} =
             run_guard(context, ["api", "graphql", "-f", "query=mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"])

    refute File.exists?(context.calls)
  end

  test "refuses a GraphQL mutation whose document the guard cannot read", context do
    # `--input` and `-F query=@file` hand gh a document that never appears in
    # argv, so no mutation name is visible to match. The request would carry
    # `addPullRequestReview` with the agent PAT, and branch protection does not
    # stop an approval.
    assert {output, 77} = run_guard(context, ["api", "graphql", "--input", "mutation.json"])
    assert output =~ "agents cannot approve or merge pull requests"

    assert {_output, 77} = run_guard(context, ["api", "graphql", "--input=mutation.json"])
    assert {_output, 77} = run_guard(context, ["api", "graphql", "--input", "-"])

    for query_file_argument <- [
          ["-F", "query=@mutation.graphql"],
          ["-Fquery=@mutation.graphql"],
          ["-F=query=@mutation.graphql"],
          ["-f", "query=@-"],
          ["-fquery=@mutation.graphql"],
          ["-f=query=@mutation.graphql"],
          ["--field=query=@mutation.graphql"],
          ["--raw-field=query=@mutation.graphql"]
        ] do
      assert {_output, 77} = run_guard(context, ["api", "graphql" | query_file_argument])
    end

    refute File.exists?(context.calls)
  end

  test "allows an inline non-merge GraphQL mutation with a file-backed variable", context do
    body_file = Path.join(context.tmp_dir, "workpad.md")
    File.write!(body_file, "Merge is a human decision; this agent does not self-merge.\n")

    query =
      "mutation($id: ID!, $body: String!) { updateIssueComment(input: {id: $id, body: $body}) { clientMutationId } }"

    assert {"ok\n", 0} =
             run_guard(context, [
               "api",
               "graphql",
               "-f",
               "query=#{query}",
               "-f",
               "id=comment-id",
               "-F",
               "body=@#{body_file}"
             ])

    assert File.read!(context.calls) == "api graphql\n"
  end

  test "refuses gh aliases and any command name the guard cannot recognise", context do
    # The denylist keys on the command name, so an alias renames the command out
    # of its reach: `alias set zz "pr merge"` then `zz 7` is a two-command merge.
    assert {output, 77} = run_guard(context, ["alias", "set", "zz", "pr merge"])
    assert output =~ "refusing a command this guard cannot inspect"

    assert {_output, 77} = run_guard(context, ["alias", "delete", "zz"])
    assert {_output, 77} = run_guard(context, ["alias", "import", "aliases.yml"])
    assert {_output, 77} = run_guard(context, ["zz", "7"])

    refute File.exists?(context.calls)
  end

  test "refuses approve flags in every spelling gh accepts", context do
    assert {output, 77} = run_guard(context, ["pr", "review", "7", "--approve=true"])
    assert output =~ "agents cannot approve or merge pull requests"

    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-a"])
    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-ab", "body"])
    assert {_output, 77} = run_guard(context, ["pr", "review", "7", "-a=true"])

    refute File.exists?(context.calls)
  end

  test "refuses the merge-gate REST endpoints that need no pull request", context do
    # Each of these advances the protected branch with no review recorded.
    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/merges", "-f", "base=main", "-f", "head=feature"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "PATCH", "repos/owner/repo/git/refs/heads/main", "-f", "sha=deadbeef"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/git/refs", "-f", "ref=refs/heads/main"])
    assert {_output, 77} = run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/pulls/7/update-branch"])

    refute File.exists?(context.calls)
  end

  test "refuses gh pr update-branch during post-handoff states but permits it in progress", context do
    assert {output, 77} =
             run_guard(context, ["pr", "update-branch", "42", "--repo", "owner/other"],
               FAKE_GH_FORMAT_OUTPUT: "priority:2 agent:human-review\\n",
               FAKE_GH_FORMAT_ARGS: context.calls
             )

    assert output =~ "ticket #1670 is handed off"
    assert output =~ "if GitHub reports the PR CONFLICTING or a reviewer asked for integration"
    assert File.read!(context.calls) =~ "repos/aiur-team/aiur/issues/1670"

    File.rm!(context.calls)

    assert {"ok\n", 0} =
             run_guard(context, ["pr", "update-branch", "42"],
               FAKE_GH_FORMAT_OUTPUT: "priority:2 agent:in-progress\\n",
               FAKE_GH_FORMAT_ARGS: context.calls
             )
  end

  # Disarming the gate is as good as passing it: an agent that can delete branch
  # protection, rewrite a ruleset, or dispatch a workflow that merges with
  # `GITHUB_TOKEN` has removed the control every other denial here relies on.
  test "refuses the ways an agent could disarm the merge gate instead of passing it", context do
    assert {_output, 77} = run_guard(context, ["api", "-X", "DELETE", "repos/owner/repo/branches/main/protection"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "PUT", "repos/owner/repo/branches/main/protection", "-f", "enforce_admins=false"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/rulesets", "-f", "name=open"])
    assert {_output, 77} = run_guard(context, ["workflow", "run", "merge.yml"])

    assert {_output, 77} =
             run_guard(context, ["api", "-X", "POST", "repos/owner/repo/actions/workflows/9/dispatches", "-f", "ref=main"])

    assert {_output, 77} = run_guard(context, ["api", "-X", "POST", "repos/owner/repo/dispatches", "-f", "event_type=merge"])

    refute File.exists?(context.calls)
  end

  test "still allows reading branch protection and listing workflows", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/branches/main/protection"])
    assert {"ok\n", 0} = run_guard(context, ["workflow", "list"])
    assert {"ok\n", 0} = run_guard(context, ["workflow", "view", "ci.yml"])
  end

  test "still allows the reads and non-approving reviews an agent legitimately needs", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/pulls/7/reviews"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "1670", "--comment", "--body", "looks reasonable"])

    assert File.read!(context.calls) =~ "pr view"
  end
end
