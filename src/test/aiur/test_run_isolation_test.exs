defmodule Aiur.TestRunIsolationTest do
  use Aiur.TestSupport

  alias Aiur.AgentEnvironment
  alias Aiur.AgentGitHubGuard

  test "scoped remote agents use per-launch paths without a shared credential" do
    previous_scope = System.get_env("AIUR_DEV_TEST_TICKET_IDS")
    previous_run_id = System.get_env("AIUR_DEV_TEST_RUN_ID")
    System.put_env("AIUR_DEV_TEST_TICKET_IDS", "99,100,101")
    System.put_env("AIUR_DEV_TEST_RUN_ID", "aiur-test-budget.unique")

    on_exit(fn ->
      restore_env("AIUR_DEV_TEST_TICKET_IDS", previous_scope)
      restore_env("AIUR_DEV_TEST_RUN_ID", previous_run_id)
    end)

    prefix = AgentEnvironment.workspace_env_export_prefix("/work/aiur/4499", base_branch: "main")

    assert prefix =~ "AIUR_GITHUB_BUDGET_ROOT=\"$HOME/.aiur/test-sandboxes/aiur-test-budget.unique/github-budget\""
    assert prefix =~ "AIUR_GITHUB_CREDENTIAL_FILE=\"$AIUR_GITHUB_BUDGET_ROOT/agent-token\""
    refute prefix =~ "~/.aiur/github-budget/agent-token"

    install_script =
      AgentGitHubGuard.remote_install_script("/work/aiur/4499",
        token: "live-bot-token",
        remote_host: "worker-1"
      )

    assert install_script =~ "test sandbox remote agents have no GitHub credential"
    refute install_script =~ "live-bot-token"
    refute install_script =~ "chmod 600 \"$HOME/.aiur/github-budget/agent-token\""
  end
end
