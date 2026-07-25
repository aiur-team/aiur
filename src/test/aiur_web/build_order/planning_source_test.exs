defmodule AiurWeb.BuildOrder.PlanningSourceTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.PlanningSource
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  @pack """
  {
    "build_order_id": "acme/widgets:demo",
    "title": "Demo Plan",
    "repository": "acme/widgets",
    "workstreams": [{"id": "core", "title": "Core"}, {"id": "web", "title": "Web"}],
    "tickets": [
      {"id": "T-1", "title": "Foundation", "lane": "core", "phase": 1, "complexity": 3, "depends_on": [],
       "document_url": "https://github.com/acme/widgets/blob/plan/docs/T-1.md"},
      {"id": "T-2", "title": "Build on it", "lane": "web", "phase": 2, "complexity": 2, "depends_on": ["T-1"]}
    ]
  }
  """

  setup do
    path = Path.join(System.tmp_dir!(), "planning-source-test-#{System.unique_integer([:positive])}.json")
    File.write!(path, @pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      File.rm(path)
    end)

    :ok
  end

  test "catalog exposes one selectable planning root" do
    snapshot = PlanningSource.catalog()

    assert %Snapshot{scope: :catalog, authority_epoch: epoch, generation: gen} = snapshot
    assert is_integer(epoch) and epoch > 0
    assert is_integer(gen) and gen > 0

    assert %Catalog{entries: [root]} = snapshot.data
    assert root.title == "Demo Plan"
    assert TrackerIdentity.joinable?(root.identity)
  end

  test "selected root builds a valid, planning-flagged view model" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)

    assert %Snapshot{scope: {:selected, _identity}} = snapshot
    assert %SelectedRoot{planning?: true} = snapshot.data

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    assert model.status == :ready
    assert model.planning?
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert Map.keys(model.summary.lanes) |> Enum.sort() == ["core", "web"]

    # Planning tickets carry their planning-doc URL so the ticket-context modal
    # can link to it instead of a not-yet-existent GitHub issue.
    node = Enum.find(model.nodes, &(&1.card.identifier == "1"))
    assert node.document_url == "https://github.com/acme/widgets/blob/plan/docs/T-1.md"
  end

  test "planning tickets render as planned with neutral dependency edges" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    grid = BuildOrderGridModel.build(model, nil)

    assert grid.planning?
    assert Enum.all?(grid.cards, &(&1.state == :planned))
    assert Enum.all?(grid.cards, &(&1.status_word == "planned"))
    assert Enum.all?(grid.edges, &(&1.state == "planned"))
  end

  test "missing pack yields no catalog rather than crashing" do
    Application.put_env(:aiur, :build_order_planning_pack, "/does/not/exist.json")
    assert PlanningSource.catalog() == nil
  end
end
