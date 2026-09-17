defmodule Aiur.BuildOrder.HomeRepositorySnapshotTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.GraphProjection.{Configuration, Options}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Repository}
  alias Aiur.GitHub.Config, as: GitHubConfig

  test "omitted repository resolves origin for generation-qualified catalog authority" do
    key = {GitHubConfig, :resolved_origin_repo}
    previous = :persistent_term.get(key, :not_cached)
    :persistent_term.put(key, "team/consumer")

    on_exit(fn ->
      if previous == :not_cached, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: nil)

    assert {:ok, _workflow, generation} = Aiur.WorkflowStore.current_with_generation()
    assert {:ok, {"team", "consumer"}, ^generation} = Repository.configured_repository_snapshot([])
    assert {:ok, authority} = Configuration.snapshot(Options.new([]), nil)
    assert authority.repository == {"team", "consumer"}
    assert authority.generation == generation

    # A later reload must not replace the repository captured by a snapshot.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "different/project")
    assert {:ok, {"different", "project"}} = GitHubConfig.configured_repo()
    assert {:ok, {"team", "consumer"}} = GitHubConfig.configured_repo_from_value(nil)
  end

  test "origin fallback stays disabled for non-GitHub workflows" do
    key = {GitHubConfig, :resolved_origin_repo}
    previous = :persistent_term.get(key, :not_cached)
    :persistent_term.put(key, "team/consumer")

    on_exit(fn ->
      if previous == :not_cached, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous)
    end)

    for kind <- ["linear", "memory"] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: kind, tracker_repo: nil)
      assert {:error, %Failure{kind: :configuration}} = Repository.configured_repository_snapshot([])
    end
  end
end
