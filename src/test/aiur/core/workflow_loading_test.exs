defmodule Aiur.Core.WorkflowLoadingTest do
  use Aiur.TestSupport

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.linear.api_key == env_api_key
    assert Config.settings!().tracker.linear.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.linear.assignee == env_assignee
  end

  test "workflow file path defaults to .aiur/config in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    try do
      Workflow.clear_workflow_file_path()

      repo_local_default = Path.join([File.cwd!(), ".aiur", "config"])
      candidates = Workflow.config_path_candidates()

      # Asserting the resolved path equals the repo-local default directly is
      # environment-dependent: discovery falls back to `~/.aiur/config`, so a
      # developer machine with a real global config resolves to *that* — correct
      # behavior, not a failure. Assert the contract instead: the repo-local path
      # leads the candidate list, discovery drives the unset-app-env result, and
      # the repo-local path is what comes back when nothing exists on disk.
      assert List.first(candidates) == repo_local_default
      assert Workflow.workflow_file_path() == Workflow.resolve_config_path(candidates)

      absent_a = Aiur.TestSupport.tmp_root!("aiur-absent-a")
      absent_b = Aiur.TestSupport.tmp_root!("aiur-absent-b")
      assert Workflow.resolve_config_path([absent_a, absent_b]) == absent_a
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "workflow file path resolves from app env when set" do
    original_workflow_path = Workflow.workflow_file_path()
    app_workflow_path = "/tmp/app/config.yaml"

    try do
      Workflow.set_workflow_file_path(app_workflow_path)

      assert Workflow.workflow_file_path() == app_workflow_path
    after
      Workflow.set_workflow_file_path(original_workflow_path)
    end
  end

  test "workflow load accepts a config with no prompt_file and an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "no-promptconfig.yaml")
    File.write!(workflow_path, "tracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects a config that does not decode to a map" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "not-a-mapconfig.yaml")
    File.write!(workflow_path, "- not-a-map\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end
end
