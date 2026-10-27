defmodule Aiur.TestRunIsolationTest do
  use Aiur.TestSupport

  alias Aiur.AgentEnvironment
  alias Aiur.AgentGitHubGuard

  test "test support gives scoped tickets a per-test state directory" do
    Aiur.TestScopeGuard.put_ticket_scope!("99")

    assert {:ok, state_dir} = Aiur.TestRunState.scope_root()
    assert state_dir == System.get_env("AIUR_DEV_TEST_STATE_DIR")
    assert String.starts_with?(state_dir, Application.fetch_env!(:aiur, :test_run_root))
  end

  test "scope leak guard rejects changed scope environment" do
    previous_scope_state = Aiur.TestScopeGuard.capture()

    on_exit(fn -> Aiur.TestScopeGuard.restore(previous_scope_state) end)

    System.put_env("AIUR_DEV_TEST_STATE_DIR", "unrestored")
    Application.put_env(:aiur, :decision_state_dir, "unrestored")

    assert message =
             Aiur.TestScopeGuard.violation(previous_scope_state)

    assert message =~ "test scope state leaked"
  end

  test "scoped remote agents use per-launch paths without a shared credential" do
    previous_run_id = System.get_env("AIUR_DEV_TEST_RUN_ID")
    on_exit(fn -> restore_env("AIUR_DEV_TEST_RUN_ID", previous_run_id) end)
    System.put_env("AIUR_DEV_TEST_RUN_ID", "aiur-test-budget.unique")
    Aiur.TestScopeGuard.put_ticket_scope!("99,100,101")

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
