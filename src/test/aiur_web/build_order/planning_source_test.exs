defmodule AiurWeb.BuildOrder.PlanningSourceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{BuildOrdersCLI, RepoBase, TrackerIdentity}
  alias Aiur.GitHub.Config
  alias AiurWeb.BuildOrder.{PlanningSource, RouteState, TicketContextAdapter, TicketContextPresenter}
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel
  alias AiurWeb.OperatorControlCenter.BuildOrderSelected

  @pack """
  {
    "build_order_id": "acme/widgets:demo",
    "title": "Demo Plan",
    "repository": "acme/widgets",
    "tickets": [
      {"id": "T-1", "title": "Foundation", "lane": "core", "phase": 1, "complexity": 3, "depends_on": [],
       "ticket": null, "doc": "tickets/T-1.md"},
      {"id": "T-2", "title": "Build on it", "lane": "web", "phase": 2, "complexity": 2, "depends_on": ["T-1"],
       "ticket": null, "doc": "tickets/T-2.md"}
    ]
  }
  """

  @canonical_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 2,
       "complexity": 3, "ticket": 4101, "doc": "tickets/AS-101.md", "depends_on": []},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 3,
       "complexity": 2, "ticket": 4102, "doc": "tickets/AS-102.md", "depends_on": ["AS-101"]}
    ]
  }
  """

  @mixed_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "icon": "bolt",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 1,
       "complexity": 3, "depends_on": [], "ticket": 4101, "doc": "tickets/AS-101.md"},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 2,
       "complexity": 2, "depends_on": ["AS-101"], "ticket": null, "doc": "tickets/AS-102.md", "icon": "sparkles"}
    ]
  }
  """

  setup do
    path = Aiur.TestSupport.tmp_root!("planning-source-test") <> ".json"
    workspace_directory = Aiur.TestSupport.tmp_root!("planning-source-workspace")
    previous_workspace_directory = Application.get_env(:aiur, :build_order_workspace_directory)
    File.write!(path, @pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)
    Application.put_env(:aiur, :build_order_workspace_directory, workspace_directory)
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 0, members: []} end)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(1, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
      Application.delete_env(:aiur, :build_order_pack_status_health_snapshot)

      if previous_workspace_directory,
        do: Application.put_env(:aiur, :build_order_workspace_directory, previous_workspace_directory),
        else: Application.delete_env(:aiur, :build_order_workspace_directory)

      File.rm(path)
      File.rm_rf(workspace_directory)
    end)

    {:ok, workspace_directory: workspace_directory}
  end

  test "full draft IDs retain distinct identities and dependency edges including T00" do
    path = Application.fetch_env!(:aiur, :build_order_planning_pack)
    pack = Jason.decode!(@pack)
    ids = ["X-C1-T01", "X-C2-T01", "X-C1-T00"]
    tickets = Enum.map(ids, &%{"id" => &1, "doc" => "tickets/#{&1}.md", "ticket" => nil, "lane" => "core", "phase" => 1, "depends_on" => []})
    tickets = List.update_at(tickets, 2, &Map.put(&1, "depends_on", Enum.take(ids, 2)))
    File.write!(path, Jason.encode!(Map.put(pack, "tickets", tickets)))

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.nodes) == 3
    assert length(model.edges) == 2
    identities = Enum.map(snapshot.data.members, & &1.identity)
    assert length(Enum.uniq_by(identities, &TrackerIdentity.github_key/1)) == 3
    assert length(Enum.uniq_by(identities, & &1.identifier)) == 3
    assert Enum.all?(identities, &(String.to_integer(&1.identifier) in 1_000_000_000_000_000_000..9_223_372_036_854_775_806))
    {:ok, repeated} = PlanningSource.demand(root.identity)
    assert Enum.map(repeated.data.members, & &1.identity) == identities
  end

  test "invalid pack identities are logged without hiding the valid pack" do
    valid = Application.fetch_env!(:aiur, :build_order_planning_pack)
    invalid = valid <> ".invalid"
    pack = @pack |> Jason.decode!() |> Map.put("repository", Config.repo()) |> Map.put("root_number", 0)
    File.write!(valid, String.replace(@pack, "acme/widgets", Config.repo()))
    File.write!(invalid, Jason.encode!(pack))
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [invalid, valid])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm(invalid)
    end)

    log =
      capture_log(fn ->
        assert [root] = PlanningSource.catalog().data.entries
        assert root.title == "Demo Plan"
        {:ok, snapshot} = PlanningSource.demand(root.identity)
        assert length(BuildOrderPresenter.present(snapshot, :unavailable, :unavailable).nodes) == 2
      end)

    assert log =~ invalid
    assert log =~ "invalid_display_identifier"
  end

  test "draft ticket context retains its title, body and relationships" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-draft-context")
    path = Path.join(directory, "build-order.json")
    File.mkdir_p!(Path.join(directory, "tickets"))
    File.write!(path, @pack)
    File.write!(Path.join(directory, "tickets/T-2.md"), "# Draft body\n\nContext remains readable.")
    Application.put_env(:aiur, :build_order_planning_pack, path)
    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    draft = Enum.find(model.nodes, &(&1.document_path == "tickets/T-2.md"))
    base = %{TicketContextPresenter.normalize_view(nil) | identity: draft.identity, title: draft.title, description: draft.draft_body}
    context = TicketContextAdapter.present(model, draft.identity, base, %{})

    assert context.status == :available
    assert context.base.identity == draft.identity
    assert context.base.title == "Build on it"
    assert context.base.description == "# Draft body\n\nContext remains readable."
    assert [blocker] = context.blocked_by
    assert blocker.label == "Foundation"
    assert blocker.selectable?
  end

  test "duplicate member identifiers reject the pack with a specific cause" do
    path = Application.fetch_env!(:aiur, :build_order_planning_pack)
    pack = Jason.decode!(@pack)
    [first, second] = pack["tickets"]
    File.write!(path, Jason.encode!(%{pack | "tickets" => [first, Map.put(second, "id", first["id"])]}))

    log = capture_log(fn -> assert PlanningSource.catalog().data.entries == [] end)
    assert log =~ path
    assert log =~ "duplicate_member_identifier"
  end

  test "catalog exposes one selectable planning root" do
    snapshot = PlanningSource.catalog()

    assert %Snapshot{scope: :catalog, authority_epoch: epoch, generation: gen} = snapshot
    assert is_integer(epoch) and epoch > 0
    assert is_integer(gen) and gen > 0

    assert %Catalog{entries: [root]} = snapshot.data
    assert root.title == "Demo Plan"
    assert TrackerIdentity.joinable?(root.identity)
    assert snapshot.membership_health.state == :unavailable
    assert snapshot.membership_health.failure == :membership_unavailable
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

    # Planning tickets retain their canonical local draft path.
    node = Enum.find(model.nodes, &(&1.document_path == "tickets/T-1.md"))
    assert node.document_path == "tickets/T-1.md"
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
    assert Enum.all?(snapshot.data.members, &is_nil(&1.url))
    assert Enum.all?(model.edges, &is_nil(&1.url))
    refute Enum.any?(model.diagnostics, &(&1.code == :invalid_url))
  end

  test "missing pack yields no catalog rather than crashing" do
    [root] = PlanningSource.catalog().data.entries
    Application.put_env(:aiur, :build_order_planning_pack, "/does/not/exist.json")
    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()

    assert {:ok, %Snapshot{data: nil, health: %{state: :unavailable, failure: :pack_unavailable}}} =
             PlanningSource.demand(root.identity)
  end

  test "excludes configured packs for another repository and reports searched directories" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-scope")
    matching = Path.join(directory, "matching.json")
    foreign = Path.join(directory, "foreign.json")
    repository = Config.repo()

    File.mkdir_p!(directory)
    File.write!(matching, String.replace(@pack, "acme/widgets", String.upcase(repository)))
    File.write!(foreign, @pack)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [matching, foreign])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm_rf(directory)
    end)

    assert %Snapshot{data: %Catalog{entries: [entry]}} = PlanningSource.catalog()
    assert entry.title == "Demo Plan"

    Application.put_env(:aiur, :build_order_planning_packs, [foreign])
    assert %Snapshot{data: %Catalog{entries: [], search_paths: search_paths}} = PlanningSource.catalog()
    assert directory in search_paths
  end

  test "loads a materialized canonical pack from the repository discovery directory" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-published")
    path = Path.join(directory, "published.json")
    repository = Config.repo()

    File.mkdir_p!(directory)

    File.write!(
      path,
      Jason.encode!(%{
        "build_order_id" => "#{repository}:published",
        "title" => "Published",
        "repository" => repository,
        "github_root" => %{"number" => 9900, "node_id" => "ROOT"},
        "tickets" => [
          %{
            "id" => "P-1",
            "title" => "Published member",
            "document" => "tickets/P-1.md",
            "workstream" => "runtime",
            "phase_hint" => 1,
            "complexity_points" => 3,
            "depends_on" => [],
            "github" => %{"number" => 9901, "node_id" => "MEMBER"}
          }
        ]
      })
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [path])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm_rf(directory)
    end)

    assert %Snapshot{data: %Catalog{entries: [root]}} = PlanningSource.catalog()
    assert root.identity.identifier == "9900"
    {:ok, selected} = PlanningSource.demand(root.identity)
    assert [%{identity: %{identifier: "9901"}}] = selected.data.members
  end

  test "hydrates canonical ticket fields from membership without tracker reads" do
    path = Aiur.TestSupport.tmp_root!("planning-source-canonical") <> ".json"
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.identity.identifier == "9900"
    assert root.identity.provider_id == "BO_acme/widgets:analytics-streamdeck"
    assert is_nil(root.progress)
    assert root.progress_resolution == :unresolved

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 7, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :completed}]}
    end)

    [hydrated_root] = PlanningSource.catalog().data.entries
    assert is_nil(hydrated_root.progress)
    assert hydrated_root.progress_resolution == :unresolved

    {:ok, hydrated} = PlanningSource.demand(root.identity)
    assert hydrated.generation > 8
    refute hydrated.data.planning?

    [closed, unknown] = hydrated.data.members
    assert closed.identity.identifier == "4101"
    assert closed.identity.provider_id == "I_live_4101"
    assert closed.lifecycle.state == :closed
    assert unknown.identity.identifier == "4102"
    assert unknown.lifecycle.state == :unknown

    model = BuildOrderPresenter.present(hydrated, :unavailable, :unavailable)
    assert Map.keys(model.summary.lanes) |> Enum.sort() == ["dashboard-ui", "runtime"]
    assert Enum.map(model.phase_groups, & &1.key) == [2, 3]

    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 60, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 2)).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).completion.progress_resolution == :unresolved
  end

  test "does not count cancelled members as completed progress" do
    path = Aiur.TestSupport.tmp_root!("planning-source-cancelled") <> ".json"
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 8, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :cancelled}]}
    end)

    [root] = PlanningSource.catalog().data.entries
    assert is_nil(root.progress)
    assert root.progress_resolution == :unresolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [cancelled, _open] = snapshot.data.members
    assert cancelled.lifecycle.state == :closed
    assert cancelled.lifecycle.state_reason == :not_planned

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 0, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).completion.progress == 0
  end

  test "uses status.json for canonical members when no live membership exists" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members
    assert created.lifecycle.state == :closed
    assert draft.lifecycle.state == :open
  end

  test "tracker completion outranks active current-run membership" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-completed")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [completed, _draft] = snapshot.data.members
    assert completed.lifecycle.state == :closed
    assert completed.lifecycle.state_reason == :completed

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    assert card.state == :merged
    assert card.completion.progress == 100
    assert card.status_word == "merged"
  end

  test "tracker reopen outranks terminal current-run membership" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-open")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"state":"completed","members":{"4101":"open"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :completed)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 0
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [reopened, _draft] = snapshot.data.members
    assert reopened.lifecycle.state == :open
    assert reopened.lifecycle.state_reason == :none

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    refute card.state == :merged
    refute card.status_word == "merged"
  end

  test "keeps the plan readable and marks a retained status projection stale" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-stale")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_unavailable
  end

  test "keeps the plan readable while missing ticket status remains unavailable" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-unavailable")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :unavailable
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_unavailable

    [root] = snapshot.data.entries
    # The draft resolves and the promoted member does not: a partial pack keeps
    # the percentage it can defend and publishes its coverage alongside it.
    assert root.progress == 0
    assert root.progress_resolution == :partial
    assert root.progress_resolved_count == 1
    assert root.member_count == 2
    {:ok, selected} = PlanningSource.demand(root.identity)
    assert selected.health.state == :healthy
    assert selected.status_health.state == :unavailable
    [promoted, draft] = selected.data.members

    assert promoted.lifecycle.state == :unknown
    assert promoted.lifecycle.state_reason == :unknown
    assert draft.lifecycle.state == :open

    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert model.status == :ready
    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 0, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress_resolution == :unresolved
  end

  test "downgrades healthy PackStatus when a promoted member lacks a projection" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-incomplete")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @canonical_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4102, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_incomplete

    [root] = snapshot.data.entries
    # One of two resolved and complete: 50% is the lower bound over both members.
    assert root.progress == 50
    assert root.progress_resolution == :partial
    assert root.progress_resolved_count == 1
    assert root.member_count == 2
    {:ok, selected} = PlanningSource.demand(root.identity)
    [completed, active] = selected.data.members

    assert completed.lifecycle.state == :closed
    assert active.lifecycle.state == :open
    assert active.lifecycle.state_reason == :none

    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)
    # The grid agrees with the catalog root: the open member with no activity reading is unresolved, not a resolved 0%.
    assert grid.overall_completion == %{progress: 60, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.waves, &(&1.phase == 2)).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).completion.progress_resolution == :unresolved
  end

  test "preserves PackStatus budget exhaustion through an incomplete projection" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-budget")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @canonical_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(2, :stale, false, failure: :planning_call_budget_exhausted)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    assert snapshot.status_health.failure == :planning_call_budget_exhausted
    refute snapshot.status_health.complete?
  end

  test "ignores a malformed status members shape" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-malformed")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":[]}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :unavailable
    assert snapshot.status_health.failure == :pack_status_incomplete
  end

  test "membership recovery does not regress the PackStatus-backed generation" do
    path = Aiur.TestSupport.tmp_root!("planning-source-generation") <> ".json"
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(5, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn -> File.rm(path) end)

    initial_generation = PlanningSource.catalog().generation

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 1, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :completed}]}
    end)

    assert PlanningSource.catalog().generation > initial_generation
  end

  test "renders created members live and uncreated members as planned from one canonical pack" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-mixed")
    path = Path.join(directory, "build-order.json")
    document = Path.join([directory, "tickets", "AS-102.md"])

    File.mkdir_p!(Path.dirname(document))
    File.write!(document, "# Render deck\n\nDraft ticket body.")
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      {:ok, colliding_draft_identity} =
        TrackerIdentity.from_github(
          %{"number" => 102, "node_id" => "I_live_102"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :fresh},
        members: [
          %{identity: identity, lifecycle: :completed},
          %{identity: colliding_draft_identity, lifecycle: :completed}
        ]
      }
    end)

    [root] = PlanningSource.catalog().data.entries
    assert root.icon == "bolt"
    assert root.progress == 50
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members
    refute created.draft?
    assert created.lifecycle.state == :closed
    assert is_nil(created.draft_body)
    assert draft.draft?
    assert draft.lifecycle.state == :open
    assert String.starts_with?(draft.identity.provider_id, "PLAN_")
    assert draft.document_path == "tickets/AS-102.md"
    assert draft.draft_body == "# Render deck\n\nDraft ticket body."

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model, nil)
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert %{state: :planned, icon: "sparkles"} = Enum.find(grid.cards, &(&1.id == draft.identity.identifier))
    assert grid.overall_completion.progress == 60
    assert Enum.find(model.nodes, & &1.card.planned?).draft_body == "# Render deck\n\nDraft ticket body."
  end

  test "rejects a draft document outside its pack ticket directory" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-document-boundary")
    path = Path.join(directory, "build-order.json")
    outside_document = directory <> ".md"

    File.mkdir_p!(directory)
    File.write!(outside_document, "must not render")
    File.write!(path, String.replace(@mixed_pack, "tickets/AS-102.md", "../#{Path.basename(outside_document)}"))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn ->
      File.rm_rf(directory)
      File.rm(outside_document)
    end)

    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()
  end

  test "uses live labels for created tickets and pack labels for drafts" do
    path = Aiur.TestSupport.tmp_root!("planning-source-live-labels") <> ".json"
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :fresh},
        members: [%{identity: identity, lifecycle: :queued}],
        labels_by_identity: %{TrackerIdentity.github_key(identity) => ["agent:rework"]}
      }
    end)

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members

    assert created.labels == ["agent:rework"]
    assert draft.labels == ["build-lane:dashboard-ui", "phase:2", "complexity:2"]
  end

  test "rejects members without canonical ticket or document fields" do
    path = Aiur.TestSupport.tmp_root!("planning-source-invalid-schema") <> ".json"

    on_exit(fn -> File.rm(path) end)

    File.write!(path, String.replace(@pack, "\"ticket\": null", "\"ticket\": -1"))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()

    File.write!(path, String.replace(@pack, "\"doc\": \"tickets/T-1.md\"", "\"doc\": \"plan.md\""))
    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()
  end

  test "marks membership recovery failures unavailable instead of trusted open state" do
    [root] = PlanningSource.catalog().data.entries

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 9, health: {:unavailable, :recovery_unavailable}, members: []}
    end)

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    assert snapshot.health.state == :healthy
    assert snapshot.health.complete?
    assert snapshot.membership_health.state == :unavailable
    assert snapshot.membership_health.failure == :membership_unavailable

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert Enum.all?(model.nodes, & &1.card.planned?)
  end

  test "unavailable membership cannot supply a terminal ticket state" do
    path = Aiur.TestSupport.tmp_root!("planning-source-unavailable-member") <> ".json"
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    {:ok, live_identity} =
      TrackerIdentity.from_github(
        %{"number" => 4101, "node_id" => "I_stale_4101"},
        {"acme", "widgets"},
        {"acme", "widgets"}
      )

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :unavailable},
        members: [%{identity: live_identity, lifecycle: :completed, labels: ["agent:done"]}]
      }
    end)

    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress_resolution == :unresolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [member | _] = snapshot.data.members
    assert member.lifecycle.state == :unknown
    assert member.identity.provider_id == "PLAN_AS-101"
    refute "agent:done" in member.labels
  end

  test "cold globally paused membership keeps a mixed materialized plan readable" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-paused-mixed")
    path = Path.join(directory, "build-order.json")
    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 0, health: :healthy, freshness: %{status: :unavailable}, members: []}
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    catalog = PlanningSource.catalog()
    assert catalog.health.state == :healthy
    assert catalog.membership_health.state == :unavailable
    assert catalog.status_health.state == :unavailable
    assert [%{identity: identity, progress_resolution: :partial}] = catalog.data.entries

    {:ok, selected} = PlanningSource.demand(identity)
    assert selected.health.state == :healthy
    assert selected.membership_health.state == :unavailable
    assert [%{lifecycle: %{state: :unknown}}, %{draft?: true}] = selected.data.members

    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert [%{url: "https://github.com/acme/widgets/issues/4101"}] = model.edges
    refute Enum.any?(model.diagnostics, &(&1.code == :invalid_url))

    {route, []} = RouteState.new("paused-test") |> RouteState.navigate("9900")
    {route, [{:activate, ^identity}]} = RouteState.put_catalog(route, catalog)
    {route, :generation} = RouteState.put_selected(route, selected)

    html =
      render_component(&BuildOrderSelected.build_order_selected/1, %{
        route_state: route,
        model: model,
        now: ~U[2026-09-29 12:00:00Z],
        analytics_scope: %{state: :none},
        usage_scope: %{state: :none}
      })

    assert html =~ "The plan is readable, but live execution state is unresolved"
    assert html =~ "Ticket status is unavailable"
    assert html =~ "Build Order graph summary"

    assert {:ok, cli} = BuildOrdersCLI.build(source: PlanningSource, root: "9900")
    assert get_in(cli, ["sources", "planning_graph", "state"]) == "available"
    assert get_in(cli, ["sources", "membership", "state"]) == "unavailable"
    assert get_in(cli, ["sources", "ticket_status", "state"]) == "unavailable"
    assert get_in(cli, ["data", "graph", "status"]) == "ready"
  end

  test "a draft blocker in a mixed pack has no invented URL or live blocking state" do
    path = Aiur.TestSupport.tmp_root!("planning-source-draft-blocker") <> ".json"

    pack =
      @mixed_pack
      |> Jason.decode!()
      |> Map.update!("tickets", fn tickets ->
        Enum.map(tickets, fn
          %{"id" => "AS-101"} = ticket -> Map.put(ticket, "depends_on", ["AS-102"])
          %{"id" => "AS-102"} = ticket -> Map.put(ticket, "depends_on", [])
        end)
      end)

    File.write!(path, Jason.encode!(pack))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    assert model.status == :ready
    assert [%{url: nil, state: :unknown}] = model.edges
    refute Enum.any?(model.diagnostics, &(&1.code == :invalid_url))
  end

  test "discovers canonical packs from the runtime build-order directory" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-discovery")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")
    repository = Config.repo()

    Application.put_env(:aiur, :repo_base_root, directory)
    path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "analytics-streamdeck", "build-order.json"])
    second_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "second-build", "build-order.json"])

    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(second_path))
    File.write!(path, String.replace(@canonical_pack, "acme/widgets", repository))

    File.write!(
      second_path,
      @canonical_pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("#{repository}:analytics-streamdeck", "#{repository}:second-build")
      |> String.replace("Analytics Stream Deck", "Second runtime build")
      |> String.replace("\"root_number\": 9900", "\"root_number\": 9901")
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(directory)
    end)

    roots = PlanningSource.catalog().data.entries
    root = Enum.find(roots, &(&1.identity.identifier == "9900"))
    assert root.identity.provider_id == "BO_#{repository}:analytics-streamdeck"
    assert Enum.map(roots, & &1.identity.identifier) |> Enum.sort() == ["9900", "9901"]
  end

  test "retains the state status projection when a workspace mirror wins definition precedence", context do
    suffix = System.unique_integer([:positive])
    workspace_directory = context.workspace_directory
    workspace_path = Path.join(workspace_directory, "planning-source-duplicate-#{suffix}.json")
    state_root = Aiur.TestSupport.tmp_root!("planning-source-duplicate-state")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")
    repository = Config.repo()

    workspace_pack = @canonical_pack |> String.replace("acme/widgets", repository) |> String.replace("Analytics Stream Deck", "Workspace copy")

    state_pack =
      @canonical_pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("Analytics Stream Deck", "State copy")

    Application.put_env(:aiur, :repo_base_root, state_root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    state_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "duplicate", "build-order.json"])

    File.mkdir_p!(Path.dirname(workspace_path))
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(workspace_path, workspace_pack)
    File.write!(state_path, state_pack)
    File.write!(Path.join(Path.dirname(state_path), "status.json"), ~s({"members":{"4101":"completed","4102":"open"}}))

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(state_root)
    end)

    log = capture_log(fn -> send(self(), {:catalog, PlanningSource.catalog()}) end)
    assert_receive {:catalog, snapshot}, 1000

    assert %Snapshot{data: %Catalog{entries: [root]}} = snapshot
    assert root.title == "Workspace copy"
    assert root.progress == 50
    assert root.progress_resolution == :resolved
    assert log =~ "discarded divergent duplicate"
    assert log =~ "workspace > state > environment > configured > explicit"
    assert log =~ "selected workspace"

    {route, []} = RouteState.new("duplicate-discovery") |> RouteState.navigate("9900")
    {route, [{:activate, identity}]} = RouteState.put_catalog(route, snapshot)

    assert identity == root.identity
    assert RouteState.status(route) == :selected_loading

    assert {:ok, %Snapshot{data: %SelectedRoot{root: %{title: "Workspace copy"}, members: members}}} = PlanningSource.demand(root.identity)
    assert Enum.find(members, &(&1.identity.identifier == "4101")).lifecycle.state == :closed

    File.write!(state_path, workspace_pack)
    identical_log = capture_log(fn -> PlanningSource.catalog() end)

    assert identical_log =~ "discarded identical mirror"
  end

  test "keeps distinct build orders that collide on an explicit root number", context do
    suffix = System.unique_integer([:positive])
    workspace_directory = context.workspace_directory
    workspace_path = Path.join(workspace_directory, "planning-source-root-collision-#{suffix}.json")
    state_root = Aiur.TestSupport.tmp_root!("planning-source-root-collision-state")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")
    repository = Config.repo()

    workspace_pack = @canonical_pack |> String.replace("acme/widgets", repository) |> String.replace("Analytics Stream Deck", "Workspace copy")

    state_pack =
      @canonical_pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("Analytics Stream Deck", "State copy")
      |> String.replace("#{repository}:analytics-streamdeck", "#{repository}:state-copy")

    Application.put_env(:aiur, :repo_base_root, state_root)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    state_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "root-collision", "build-order.json"])

    File.mkdir_p!(Path.dirname(workspace_path))
    File.mkdir_p!(Path.dirname(state_path))
    File.write!(workspace_path, workspace_pack)
    File.write!(state_path, state_pack)

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(state_root)
    end)

    snapshot = PlanningSource.catalog()

    assert %Snapshot{data: %Catalog{entries: entries}} = snapshot
    assert Enum.map(entries, & &1.title) |> Enum.sort() == ["State copy", "Workspace copy"]

    {route, []} = RouteState.new("duplicate-root-number") |> RouteState.navigate("9900")
    {route, []} = RouteState.put_catalog(route, snapshot)

    assert RouteState.status(route) == :invalid_catalog
    assert RouteState.selected_identity(route) == nil
  end

  test "does not reconcile discovery packs without explicit build order IDs" do
    first = Aiur.TestSupport.tmp_root!("planning-source-missing-id-first") <> ".json"
    second = Aiur.TestSupport.tmp_root!("planning-source-missing-id-second") <> ".json"
    repository = Config.repo()

    first_pack =
      @canonical_pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("Analytics Stream Deck", "First legacy pack")
      |> String.replace(~s("build_order_id": "#{repository}:analytics-streamdeck",\n), "")

    second_pack =
      @canonical_pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("Analytics Stream Deck", "Second legacy pack")
      |> String.replace(~s("build_order_id": "#{repository}:analytics-streamdeck",\n), "")

    File.write!(first, first_pack)
    File.write!(second, second_pack)
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [first, second])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm(first)
      File.rm(second)
    end)

    log = capture_log(fn -> send(self(), {:catalog, PlanningSource.catalog()}) end)
    assert_receive {:catalog, %Snapshot{data: %Catalog{entries: entries}}}, 1000
    # Assert the absence of the *relevant* message rather than of all output:
    # `capture_log/1` captures the global Logger, so `log == ""` is falsifiable by
    # any unrelated process that happens to log during this block (#1747).
    refute log =~ "build order catalog discarded"
    assert Enum.map(entries, & &1.title) |> Enum.sort() == ["First legacy pack", "Second legacy pack"]
  end

  test "assigns distinct deterministic catalog icons when packs omit one" do
    first = Aiur.TestSupport.tmp_root!("planning-source-first") <> ".json"
    second = Aiur.TestSupport.tmp_root!("planning-source-second") <> ".json"

    repository = Config.repo()
    File.write!(first, String.replace(@pack, "acme/widgets", repository))

    File.write!(
      second,
      @pack
      |> String.replace("acme/widgets", repository)
      |> String.replace("#{repository}:demo", "#{repository}:second-demo")
      |> String.replace("Demo Plan", "Second Demo Plan")
      |> String.replace("\"T-1\"", "\"S-1\"")
      |> String.replace("\"T-2\"", "\"S-2\"")
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [first, second])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm(first)
      File.rm(second)
    end)

    icons = PlanningSource.catalog().data.entries |> Enum.map(& &1.icon)
    assert Enum.uniq(icons) |> length() == 2

    root_ids = PlanningSource.catalog().data.entries |> Enum.map(& &1.identity.identifier)
    assert Enum.uniq(root_ids) |> length() == 2
  end

  test "pins active build orders before completed entries sorted by completion date" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-catalog-sort")
    active = Path.join([directory, "active", "build-order.json"])
    recent = Path.join([directory, "recent", "build-order.json"])
    older = Path.join([directory, "older", "build-order.json"])

    for path <- [active, recent, older], do: File.mkdir_p!(Path.dirname(path))

    repository = Config.repo()
    pack = String.replace(@pack, "acme/widgets", repository)

    File.write!(active, pack)
    File.write!(recent, pack |> String.replace("Demo Plan", "Recent completed") |> String.replace(":demo", ":recent"))
    File.write!(older, pack |> String.replace("Demo Plan", "Older completed") |> String.replace(":demo", ":older"))
    File.write!(Path.join(Path.dirname(recent), "status.json"), ~s({"state":"completed","completed_at":"2026-08-01T12:00:00Z"}))
    File.write!(Path.join(Path.dirname(older), "status.json"), ~s({"state":"completed","completed_at":"2026-07-31T12:00:00Z"}))

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [older, active, recent])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm_rf(directory)
    end)

    entries = PlanningSource.catalog().data.entries
    assert Enum.map(entries, & &1.title) == ["Demo Plan", "Recent completed", "Older completed"]
    assert Enum.map(entries, & &1.completed?) == [false, true, true]
  end

  defp put_membership(number, lifecycle) do
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => number, "node_id" => "I_live_#{number}"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 9, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: lifecycle}]}
    end)
  end
end
