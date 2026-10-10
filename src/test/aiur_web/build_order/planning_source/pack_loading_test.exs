defmodule AiurWeb.BuildOrder.PlanningSource.PackLoadingTest do
  use AiurWeb.BuildOrder.PlanningSourceCase

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

  test "duplicate member identifiers reject the pack with a specific cause" do
    path = Application.fetch_env!(:aiur, :build_order_planning_pack)
    pack = Jason.decode!(@pack)
    [first, second] = pack["tickets"]
    File.write!(path, Jason.encode!(%{pack | "tickets" => [first, Map.put(second, "id", first["id"])]}))

    log = capture_log(fn -> assert PlanningSource.catalog().data.entries == [] end)
    assert log =~ path
    assert log =~ "duplicate_member_identifier"
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

  test "rejects members without canonical ticket or document fields" do
    path = Aiur.TestSupport.tmp_root!("planning-source-invalid-schema") <> ".json"

    on_exit(fn -> File.rm(path) end)

    File.write!(path, String.replace(@pack, "\"ticket\": null", "\"ticket\": -1"))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()

    File.write!(path, String.replace(@pack, "\"doc\": \"tickets/T-1.md\"", "\"doc\": \"plan.md\""))
    assert %Snapshot{data: %Catalog{entries: []}} = PlanningSource.catalog()
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
end
