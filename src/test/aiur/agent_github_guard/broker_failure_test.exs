defmodule Aiur.AgentGitHubGuard.BrokerFailureTest do
  use Aiur.AgentGitHubGuardCase, async: false

  test "a broker failure refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: context.failing_broker,
               GITHUB_TOKEN: "shared-test-credential"
             )

    assert output =~ "refusing uncoordinated request"
    assert output =~ budget_root
    assert output =~ "simulated broker abort"

    # The broker said why it failed, so the wrapper must not talk over it with a
    # guess. This path used to print only the ownership/permissions/writableRoots
    # recovery text, which named a cause that has nothing to do with a broker
    # that aborted on its own and sent readers to repair a directory the caller
    # had just created successfully (#2499).
    refute output =~ "agent.codex.turn_sandbox_policy.writableRoots"
    refute File.exists?(context.calls)
  end
end
