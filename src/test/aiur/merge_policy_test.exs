defmodule Aiur.MergePolicyTest do
  use Aiur.TestSupport

  alias Aiur.MergePolicy

  test "current reads the live workflow policy and returns nested plain maps" do
    policy("full_ci_labels: [hotfix]\n  premerge_checks: [make check]")
    result = MergePolicy.current()
    assert result.ci == "wait"
    assert result.local_tests == "partial"
    assert result.full_ci_labels == ["hotfix"]
    assert result.premerge_checks == ["make check"]
    assert result.main_watch == %{enabled: false, workflows: [], on_red: "alert", fixer_label: "main-fix", canary_minutes: 45, red_fallback_minutes: 0}
    refute Map.has_key?(result, :__struct__)
    refute Map.has_key?(result.main_watch, :__struct__)
  end

  test "full CI labels match case insensitively and reject unrelated labels" do
    policy("full_ci_labels: [main-fix]")
    assert MergePolicy.requires_full_ci?(["Main-Fix"], [])
    refute MergePolicy.requires_full_ci?(["fix"], [])
    refute MergePolicy.requires_full_ci?([], [])
  end

  test "path globs match deleted and nested paths without reading the filesystem" do
    policy("full_ci_paths: ['.github/workflows/**', 'src/**/critical?.ex', 'mix.*']")
    assert MergePolicy.requires_full_ci?([], [".github/workflows/deleted.yml"])
    assert MergePolicy.requires_full_ci?([], ["src/critical1.ex"])
    assert MergePolicy.requires_full_ci?([], ["src/lib/deep/critical2.ex"])
    assert MergePolicy.requires_full_ci?([], ["mix.lock"])
    refute MergePolicy.requires_full_ci?([], ["docs/mix.lock", "src/lib/critical12.ex", ".github/workflows-other/ci.yml"])
  end

  test "repository policy requires full CI for workflow and dependency changes" do
    repo_config = Path.expand("../../../.aiur/config", __DIR__)
    assert {:ok, config} = Aiur.Yaml.read_from_file(repo_config)
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path)
    File.write!(path, File.read!(path) <> "\nmerge_policy: " <> Jason.encode!(config["merge_policy"]) <> "\n")
    assert :ok = Aiur.WorkflowStore.force_reload()

    for changed_path <- ["src/mix.lock", "src/mix.exs", ".github/workflows/ci.yml"] do
      assert MergePolicy.requires_full_ci?([], [changed_path])
    end

    refute MergePolicy.requires_full_ci?([], ["src/README.md"])
  end

  defp policy(fields) do
    path = Aiur.Workflow.workflow_file_path()
    write_workflow_file!(path)
    File.write!(path, File.read!(path) <> "\nmerge_policy:\n  #{fields}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
  end
end
