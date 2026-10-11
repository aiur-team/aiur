defmodule AiurWeb.BuildOrder.PlanningSourceTest do
  use AiurWeb.BuildOrder.PlanningSourceCase

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
end
