defmodule Aiur.BuildOrder.HomeRepositorySnapshotTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.GraphProjection.{Configuration, Options}
  alias Aiur.BuildOrder.TicketDetail.Repository

  test "omitted repository resolves origin for generation-qualified catalog authority" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: nil)
    key = {Aiur.GitHub.Config, :resolved_origin_repo}
    previous = :persistent_term.get(key, :not_cached)
    :persistent_term.put(key, "team/consumer")

    on_exit(fn ->
      if previous == :not_cached, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous)
    end)

    assert {:ok, _workflow, generation} = Aiur.WorkflowStore.current_with_generation()
    assert {:ok, {"team", "consumer"}, ^generation} = Repository.configured_repository_snapshot([])
    assert {:ok, authority} = Configuration.snapshot(Options.new([]), nil)
    assert authority.repository == {"team", "consumer"}
    assert authority.generation == generation
  end
end
