defmodule Aiur.AgentSetupScout.GitHubReporterTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentSetupScout.GitHubReporter

  defmodule FakeClient do
    def create_issue(title, body, labels) do
      send(self(), {:unexpected_self_call, title, body, labels})
      {:error, :not_configured}
    end
  end

  defmodule ProcessClient do
    def create_issue(title, body, labels) do
      send(Process.get(:test_pid), {:create_issue, title, body, labels})
      {:ok, %{"number" => 123}}
    end
  end

  setup do
    original = Application.get_env(:aiur, :agent_setup_scout_github_client)

    on_exit(fn ->
      restore_app_env(:agent_setup_scout_github_client, original)
    end)

    :ok
  end

  test "reports findings through the configured GitHub client" do
    Process.put(:test_pid, self())
    Application.put_env(:aiur, :agent_setup_scout_github_client, ProcessClient)

    finding = %{
      title: "Install rg",
      body: "## Pattern observed\n\nrg missing",
      labels: ["enhancement", "agent-setup-optimization", "needs-triage"]
    }

    assert :ok = GitHubReporter.report(finding)

    assert_received {:create_issue, "Install rg", "## Pattern observed\n\nrg missing", ["enhancement", "agent-setup-optimization", "needs-triage"]}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
