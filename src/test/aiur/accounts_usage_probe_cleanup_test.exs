defmodule Aiur.AccountsUsageProbeCleanupTest do
  use Aiur.TestSupport

  alias Aiur.Accounts
  alias Aiur.CodexProber

  test "Codex usage removes its probe workspace from the configured root" do
    home = Aiur.TestSupport.tmp_root!("aiur-accounts-probe")
    File.mkdir_p!(home)
    previous_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      Aiur.TestCleanup.rm_rf!(home)
    end)

    workflow_path = Application.fetch_env!(:aiur, :workflow_file_path)
    workspace_root = Path.join(Path.dirname(workflow_path), "workspaces")
    File.mkdir_p!(workspace_root)
    :ok = Accounts.register("codex", "work", nil)
    profile = Path.join([home, ".aiur/accounts/codex/work"])
    write_workflow_file!(workflow_path, workspace_root: workspace_root)

    assert [{"CODEX_HOME", ^profile}] = Accounts.profile_env("codex", "work")

    assert {:ok, %{"primary" => %{"usedPercent" => 8}}} =
             CodexProber.fetch_limits("codex",
               codex_home: profile,
               start_port_fun: fn workspace, nil, nil, nil, env ->
                 send(self(), {:probe_workspace, workspace})
                 assert env == [{"CODEX_HOME", profile}]
                 {:ok, :fake_port}
               end,
               initialize_fun: fn :fake_port -> :ok end,
               read_rate_limits_fun: fn :fake_port -> {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 8}}}} end,
               stop_port_fun: fn :fake_port -> :ok end
             )

    assert_received {:probe_workspace, probe_workspace}
    workspace_under_root? = String.starts_with?(Path.expand(probe_workspace) <> "/", Path.expand(workspace_root) <> "/")
    assert workspace_under_root?
    refute File.exists?(probe_workspace)
    assert Path.wildcard(Path.join(workspace_root, "codex-usage-probe-*")) == []
  end
end
