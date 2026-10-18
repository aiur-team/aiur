defmodule Aiur.Workspace.PreflightBoundaryTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.WorkspacePreflight
  alias Aiur.Workspace.Hooks

  defmodule AlertSink do
    def emit_custom(topic, message, opts) do
      send(self(), {:preflight_alert, topic, message, opts})
      :ok
    end
  end

  setup do
    keys = [:workspace_preflights, :workspace_github_preflight_enabled, :workspace_github_preflight_fun, :signal]
    previous = Map.new(keys, &{&1, Application.fetch_env(:aiur, &1)})
    Application.put_env(:aiur, :workspace_preflights, %{"github" => WorkspacePreflight})
    Application.put_env(:aiur, :workspace_github_preflight_enabled, true)
    Application.put_env(:aiur, :signal, alert_sink: AlertSink)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)
    end)

    {:ok, issue_context: %{issue_id: "3299", issue_identifier: "3299"}}
  end

  test "preflight runs only for a tracker kind with a registered provider", %{issue_context: issue_context} do
    Application.put_env(:aiur, :workspace_github_preflight_fun, fn workspace, host ->
      send(self(), {:preflight_probe, workspace, host})
      :ok
    end)

    for kind <- ["linear", "memory"] do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: kind)
      assert :ok = Hooks.run_github_preflight("/workspace", issue_context, "worker")
      refute_received {:preflight_probe, _, _}
    end

    github_workflow!()
    assert :ok = Hooks.run_github_preflight("/workspace", issue_context, "worker")
    assert_received {:preflight_probe, "/workspace", "worker"}

    Application.put_env(:aiur, :workspace_preflights, %{})
    assert :ok = Hooks.run_github_preflight("/workspace", issue_context, "worker")
    refute_received {:preflight_probe, _, _}
  end

  # Preserves the existing #2429 guarantee through the registered provider.
  test "local budget hold fails closed without a connectivity alert", %{issue_context: issue_context} do
    github_workflow!()
    hold = {:aiur, :locally_held, %{reason: :shared_budget, resource: "core"}}
    Application.put_env(:aiur, :workspace_github_preflight_fun, fn -> {:error, hold} end)

    assert {:error, {:workspace_github_connectivity_failed, "/workspace", ^hold}} =
             Hooks.run_github_preflight("/workspace", issue_context, nil)

    refute_received {:preflight_alert, _, _, _}
  end

  test "registered provider preserves failure diagnostics and remote worker alert fields", %{issue_context: issue_context} do
    github_workflow!()
    Application.put_env(:aiur, :workspace_github_preflight_fun, fn _workspace -> :unexpected end)
    reason = {:unexpected_workspace_github_preflight_result, :unexpected}

    assert {:error, {:workspace_github_connectivity_failed, "/workspace", ^reason}} =
             Hooks.run_github_preflight("/workspace", issue_context, "worker")

    assert_received {:preflight_alert, "system.github.connectivity_lost", message, opts}

    assert message ==
             "GitHub workspace preflight failed issue_id=3299 issue_identifier=3299 workspace=/workspace " <>
               "repo=owner/repo. Probe: GET https://api.github.com/rate_limit; " <>
               "GET https://api.github.com/repos/owner/repo; " <>
               "GET https://api.github.com/repos/owner/repo/issues?state=open&per_page=1. " <>
               "Reason: {:unexpected_workspace_github_preflight_result, :unexpected}"

    assert opts == [reason: message, needs_attention: true, severity: "warning", workspace: "/workspace", worker_host: "worker"]
  end

  defp github_workflow! do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
  end
end
