defmodule Aiur.AgentGitHubGuard.IssueCreateTest do
  use Aiur.AgentGitHubGuardCase, async: true

  # #1793: 29 tickets were filed mid-run with no `agent:*` label. Each one was
  # undispatchable and absent from every state-scoped view, so the fleet read as
  # having no work left. The skills instruct every filing path to set the
  # disposition in the creation request; this is the part that does not depend
  # on an agent following prose.
  test "an issue create with no dispatch disposition never reaches gh", context do
    assert {output, 78} = run_guard(context, ["issue", "create", "--title", "Something broke"])

    assert output =~ "no dispatch disposition"
    refute File.exists?(context.calls)
  end

  test "a create labelled only with non-lifecycle labels is still refused", context do
    assert {_output, 78} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,area:dashboard"])

    refute File.exists?(context.calls)
  end

  test "each documented disposition reaches gh, in every flag spelling", context do
    for label <- ~w(agent:todo human:todo needs-triage build-order epic) do
      File.rm_rf!(context.calls)

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label=#{label}"])

      assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x", "-l", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,#{label}"])

      assert File.read!(context.calls) == String.duplicate("issue create\n", 4)
    end
  end

  test "marker, terminal, malformed, and unknown prefixed labels are not dispositions", context do
    for label <- ~w(agent:watch agent:paused agent:done agent:not-a-state team:todo :todo Agent:todo) do
      File.rm_rf!(context.calls)

      assert {output, 78} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", label])

      assert output =~ "no dispatch disposition"
      refute File.exists?(context.calls)
    end
  end

  test "the configured lifecycle prefix is the only prefixed todo disposition", context do
    assert {"ok\n", 0} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "team:todo"], AIUR_GITHUB_LABEL_PREFIX: "team")

    assert {output, 78} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "agent:todo"], AIUR_GITHUB_LABEL_PREFIX: "team")

    assert output =~ "no dispatch disposition"
  end

  test "root repository flags cannot bypass disposition validation", context do
    for arguments <- [
          ["-R", "owner/repo", "issue", "create", "--title", "x"],
          ["--repo=owner/repo", "issue", "create", "--title", "x"],
          ["issue", "--repo", "owner/repo", "create", "--title", "x"]
        ] do
      assert {output, 78} = run_guard(context, arguments)
      assert output =~ "no dispatch disposition"
    end
  end

  test "the disposition guard does not touch other issue subcommands", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "comment", "1670", "--body", "hi"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--add-label", "agent:done"])

    assert File.read!(context.calls) =~ "issue comment"
  end

  test "direct gh api issue creation never reaches GitHub", context do
    for arguments <- [
          ["api", "repos/owner/repo/issues", "-f", "title=x"],
          ["api", "/repos/owner/repo/issues/?page=1", "-XPOST"],
          ["api", "repos/owner/repo/issues", "-X=POST"],
          ["api", "https://api.github.com/repos/owner/repo/issues#new", "--method", "POST"],
          ["api", "repos/owner/repo/issues", "-X", "POST"],
          ["api", "repos/owner/repo/issues", "--method=POST"],
          ["api", "repos/owner/repo/issues", "--input", "payload.json"]
        ] do
      File.rm_rf!(context.calls)
      assert {output, 78} = run_guard(context, arguments)
      assert output =~ "use `gh issue create --label ...`"
      refute File.exists?(context.calls)
    end
  end

  # The #1793 arm matched `issues?*` with `?` as a glob wildcard, so it claimed
  # every issue subresource as well as the collection. An agent updating its own
  # workpad comment was refused and told to run `gh issue create`.
  test "editing an issue or its comments is not mistaken for issue creation", context do
    for arguments <- [
          ["api", "repos/owner/repo/issues/comments/5260269359", "-X", "PATCH", "-f", "body=workpad"],
          ["api", "repos/owner/repo/issues/1670", "-X", "PATCH", "-f", "state=closed"],
          ["api", "repos/owner/repo/issues/1670/labels", "-X", "POST", "-f", "labels[]=agent:done"],
          ["api", "repos/owner/repo/issues/1670/comments", "-X", "POST", "-f", "body=hi"]
        ] do
      assert {output, 0} = run_guard(context, arguments)
      refute output =~ "gh issue create"
    end
  end

  test "direct GraphQL issue creation never reaches GitHub", context do
    assert {output, 78} =
             run_guard(context, [
               "api",
               "graphql",
               "-f",
               "query=mutation { createIssue(input: {repositoryId: \"R\", title: \"x\"}) { issue { id } } }"
             ])

    assert output =~ "use `gh issue create --label ...`"
    refute File.exists?(context.calls)
  end

  test "file-backed GraphQL issue creation never reaches GitHub", context do
    mutation = Path.join(context.workspace, "mutation.graphql")
    query = Path.join(context.workspace, "query.graphql")
    File.write!(mutation, "mutation { createIssue(input: {}) { issue { id } } }")
    File.write!(query, "query { viewer { login } }")

    assert {output, 78} =
             run_guard(context, ["api", "graphql", "-F", "query=@#{mutation}"])

    assert output =~ "use `gh issue create --label ...`"
    refute File.exists?(context.calls)

    # A file-backed body is opaque to this process, and the pre-existing merge
    # gate denies an unreadable body outright (an invariant that predates
    # #1793). The read-only file-backed query is therefore refused by that gate
    # (77) rather than passed through; assert the message proves the #1793
    # dispatch guard is not the blocker.
    assert {output, 77} = run_guard(context, ["api", "graphql", "-F", "query=@#{query}"])
    assert output =~ "cannot approve or merge"
    refute File.exists?(context.calls)

    # An inline read-only query is not a hidden body, so both the dispatch
    # guard and the merge gate pass it through untouched.
    assert {"ok\n", 0} =
             run_guard(context, ["api", "graphql", "-f", "query={ viewer { login } }"])

    assert File.read!(context.calls) == "api graphql\n"

    for field <- ["-Fquery=@#{mutation}", "-F=query=@#{mutation}"] do
      File.rm_rf!(context.calls)
      assert {output, 78} = run_guard(context, ["api", "graphql", field])
      assert output =~ "use `gh issue create --label ...`"
      refute File.exists?(context.calls)
    end
  end

  test "opaque GraphQL input is denied by the merge gate, not the dispatch guard", context do
    # An opaque body cannot be confirmed as issue creation, so the #1793
    # dispatch guard defers it to the pre-existing merge gate, which denies
    # every unreadable GraphQL body outright (it cannot rule out a merge). The
    # command is still blocked; only the refusing message differs. Asserting
    # the merge-gate message here guards against the dispatch guard claiming an
    # opaque body that might be a merge.
    assert {output, 77} = run_guard(context, ["api", "graphql", "--input", "-"])
    assert output =~ "cannot approve or merge"
    refute File.exists?(context.calls)
  end

  test "read-only issue API calls remain available", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "-X", "GET", "-f", "state=open"])

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues", "-X=GET", "-f", "state=open"])

    assert File.read!(context.calls) == String.duplicate("api repos/owner/repo/issues\n", 3)
  end

  test "installer rejects symlinked runtime directories", context do
    runtime = Path.join(context.workspace, ".aiur-runtime")
    external = Path.join(Path.dirname(context.workspace), "outside")
    File.rm_rf!(runtime)
    File.mkdir_p!(external)
    File.ln_s!(external, runtime)

    assert {:error, {:unsafe_agent_support_path, ^runtime, :symlink}} =
             AgentGitHubGuard.install(context.workspace)

    refute File.exists?(Path.join(external, "bin/gh"))
  end
end
