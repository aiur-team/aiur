defmodule Aiur.AgentGitHubGuard.CrossTicketWritesTest do
  use Aiur.AgentGitHubGuardCase, async: true

  # The dispatch gate honors GitHub blocked-by links, and labels drive the
  # ticket lifecycle. A worker writing either on another ticket can stall work
  # it does not own, so those writes go through aiur_declare_blocker (own
  # ticket) or an Executor decision. The case workspace is `.../1670`, so 1670
  # is the worker's own ticket.

  test "refuses raw dependency and sub-issue writes on any issue", context do
    for args <- [
          ["api", "-X", "POST", "repos/o/r/issues/742/dependencies/blocked_by", "-F", "issue_id=1"],
          ["api", "--method", "DELETE", "repos/o/r/issues/1670/dependencies/blocked_by/9"],
          ["api", "repos/o/r/issues/1670/sub_issues", "-F", "sub_issue_id=1"],
          ["api", "-X", "DELETE", "/repos/o/r/issues/7/sub_issue", "-F", "sub_issue_id=1"],
          ["api", "-X", "PATCH", "repos/o/r/issues/7/sub_issues/priority", "-F", "sub_issue_id=1"],
          ["api", "graphql", "-f", "query=mutation { addBlockedBy(input: {}) { clientMutationId } }"],
          ["api", "graphql", "-f", "query=mutation { removeBlockedBy(input: {}) { clientMutationId } }"],
          ["api", "graphql", "-f", "query=mutation { addSubIssue(input: {}) { clientMutationId } }"],
          ["api", "graphql", "-f", "query=mutation { removeSubIssue(input: {}) { clientMutationId } }"],
          ["api", "graphql", "-f", "query=mutation { reprioritizeSubIssue(input: {}) { clientMutationId } }"]
        ] do
      assert {output, 77} = run_guard(context, args), inspect(args)
      assert output =~ "aiur_declare_blocker"
      assert output =~ "decision"
    end

    refute File.exists?(context.calls)
  end

  test "dependency reads still reach gh", context do
    assert {output, 0} = run_guard(context, ["api", "repos/o/r/issues/742/dependencies/blocked_by", "--jq", ".[].number"])
    refute output =~ "aiur_declare_blocker"
  end

  test "refuses label writes on another ticket", context do
    for args <- [
          ["issue", "edit", "742", "--add-label", "bug"],
          ["issue", "edit", "--remove-label=agent:todo", "742"],
          ["issue", "edit", "https://github.com/o/r/issues/742", "--add-label", "bug"],
          ["issue", "edit", "1670", "742", "--add-label", "bug"],
          ["api", "repos/o/r/issues/742/labels", "-f", "labels[]=bug"],
          ["api", "-X", "DELETE", "repos/o/r/issues/742/labels/bug"],
          ["api", "-X", "PATCH", "repos/o/r/issues/742", "-f", "labels[]=bug"]
        ] do
      assert {output, 77} = run_guard(context, args), inspect(args)
      assert output =~ "other tickets"
    end

    refute File.exists?(context.calls)
  end

  test "label writes on the worker's own ticket and non-label edits elsewhere are allowed", context do
    for args <- [
          ["issue", "edit", "1670", "--add-label", "bug"],
          ["issue", "edit", "#1670", "--remove-label", "bug", "--body", "742"],
          ["api", "repos/o/r/issues/1670/labels", "-f", "labels[]=bug"],
          ["issue", "edit", "742", "--title", "Rename"],
          ["api", "-X", "PATCH", "repos/o/r/issues/742", "-f", "state=closed"]
        ] do
      assert {output, _status} = run_guard(context, args)
      refute output =~ "other tickets", inspect(args)
    end
  end

  test "the Executor's copy is unaffected", context do
    assert {output, _status} = run_executor_guard(context, ["issue", "edit", "742", "--add-label", "bug"], [])
    refute output =~ "other tickets"

    assert {output, _status} =
             run_executor_guard(context, ["api", "-X", "POST", "repos/o/r/issues/742/dependencies/blocked_by", "-F", "issue_id=1"], [])

    refute output =~ "aiur_declare_blocker"
  end
end
