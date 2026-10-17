defmodule Aiur.Workspace.SupportBoundaryTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.Provisioner.AgentSupport

  defmodule Support do
    def install(workspace) do
      send(self(), {:installed, workspace})
      :ok
    end

    def missing_workspace_support(workspace) do
      send(self(), {:checked, workspace})
      []
    end

    def remote_install_script(workspace, opts), do: "support #{workspace} #{opts[:remote_host]}"
  end

  setup do
    previous = Application.fetch_env(:aiur, :agent_support_modules)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :agent_support_modules, value)
        :error -> Application.delete_env(:aiur, :agent_support_modules)
      end
    end)

    :ok
  end

  test "registered support keeps the current local and remote install order" do
    assert AgentSupport.support_modules(:local) == [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentBuildGuard, Aiur.AgentScratch, Aiur.Workspace.AttributionGuard]
    assert AgentSupport.support_modules(:remote) == [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentScratch]
    Application.put_env(:aiur, :agent_support_modules, [Support])
    assert AgentSupport.support_modules(:remote) == [Aiur.AgentSkills, Support, Aiur.AgentScratch]
  end

  test "dispatch verification and guard repair use registered support" do
    Application.put_env(:aiur, :agent_support_modules, [Support])
    assert :ok = AgentSupport.ensure_local_agent_support("/workspace")
    assert_received {:checked, "/workspace"}
    assert :ok = AgentSupport.repair_agent_github_guard("/workspace", nil)
    assert_received {:installed, "/workspace"}

    runner = fn host, script, _timeout ->
      assert host == "worker"
      assert script == "support /workspace worker"
      {:ok, {"", 0}}
    end

    assert :ok = AgentSupport.repair_agent_github_guard("/workspace", "worker", runner)
  end
end
