defmodule Aiur.BuildOrdersCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{BuildOrdersCLI, TrackerIdentity}

  @repository {"owner", "repo"}
  @observed_at ~U[2026-08-09 12:00:00Z]
  @captured_at ~U[2026-08-09 12:00:05Z]

  defmodule Source do
    def catalog, do: Process.get(:build_orders_catalog)
    def demand(_identity), do: Process.get(:build_orders_selected)
    def load_runtime_sources, do: Process.get(:build_orders_sources)
  end

  defmodule ContextSource do
    def catalog(_context), do: Process.get(:build_orders_catalog)
    def demand(_context, _identity), do: Process.get(:build_orders_selected)
    def load_runtime_sources(_context), do: Process.get(:build_orders_sources)
  end

  setup do
    root = root(identity(100))
    health = ProviderHealth.new(7, :healthy, true, observed_at: @observed_at)

    completed = member(1, state: :closed, state_reason: :completed)
    active = member(2, dependencies: [Dependency.new(identity(2), identity(1), issue_url(1), :blocked_by)])
    unresolved = member(3, state: :unknown, dependencies: [Dependency.new(identity(3), identity(2), issue_url(2), :blocked_by)])

    Process.put(
      :build_orders_catalog,
      %Snapshot{
        scope: :catalog,
        repository: @repository,
        generation: 7,
        data: Catalog.new([root], health),
        health: health
      }
    )

    Process.put(
      :build_orders_selected,
      {:ok,
       %Snapshot{
         scope: {:selected, root.identity},
         repository: @repository,
         generation: 7,
         data: SelectedRoot.new(root, [unresolved, active, completed], health),
         health: health
       }}
    )

    Process.put(:build_orders_sources, %{execution: %{running: [], retrying: [], idle: []}, activity: %{generation: 12, entries: [], diagnostics: %{}}})
    :ok
  end

  test "lists the dashboard catalog with source freshness and no fabricated progress" do
    assert {:ok, envelope} = BuildOrdersCLI.build(source: Source, now: @captured_at)

    assert envelope["schema_version"] == 1
    assert envelope["page"] == "build-orders"
    assert envelope["snapshot"]["captured_at"] == "2026-08-09T12:00:05Z"

    assert envelope["sources"]["planning_catalog"] == %{
             "age_ms" => 5_000,
             "freshness" => "current",
             "observed_at" => "2026-08-09T12:00:00Z",
             "partial" => false,
             "reasons" => [],
             "state" => "available"
           }

    [root] = envelope["data"]["catalog"]["entries"]
    assert root["title"] == "Build Order"
    assert root["progress"] == nil
    assert root["progress_resolution"] == "unknown"
  end

  test "preserves each catalog completion resolution in JSON and human output" do
    health = ProviderHealth.new(7, :healthy, true, observed_at: @observed_at)

    entries = [
      RootSummary.new(%{identity: identity(101), title: "Resolved", member_count: 35, progress: 60, progress_resolution: :resolved, progress_resolved_count: 35}),
      RootSummary.new(%{identity: identity(102), title: "Partial", member_count: 35, progress: 60, progress_resolution: :partial, progress_resolved_count: 21}),
      RootSummary.new(%{identity: identity(103), title: "Unresolved", member_count: 35, progress: nil, progress_resolution: :unresolved, progress_resolved_count: 0}),
      RootSummary.new(%{identity: identity(104), title: "Not reported", member_count: 35})
    ]

    Process.put(
      :build_orders_catalog,
      %Snapshot{scope: :catalog, repository: @repository, generation: 7, data: Catalog.new(entries, health), health: health}
    )

    assert {:ok, envelope} = BuildOrdersCLI.build(source: Source, now: @captured_at)

    resolutions =
      envelope["data"]["catalog"]["entries"]
      |> Map.new(&{&1["title"], {&1["progress"], &1["progress_resolution"], &1["progress_resolved_count"]}})

    assert resolutions == %{
             "Resolved" => {60, "resolved", 35},
             "Partial" => {60, "partial", 21},
             "Unresolved" => {nil, "unresolved", 0},
             "Not reported" => {nil, "unknown", nil}
           }

    output = capture_io(fn -> assert 0 == BuildOrdersCLI.run(source: Source, now: @captured_at) end)
    assert output =~ "completion 60%"
    assert output =~ "completion 60% (of 21/35 resolved)"
    assert output =~ "completion unknown"
    assert output =~ "completion not reported"

    json = capture_io(fn -> assert 0 == BuildOrdersCLI.run(json: true, source: Source, now: @captured_at) end)
    [partial | _] = Jason.decode!(json)["data"]["catalog"]["entries"] |> Enum.filter(&(&1["title"] == "Partial"))
    assert Map.take(partial, ["progress", "progress_resolution", "progress_resolved_count"]) == %{"progress" => 60, "progress_resolution" => "partial", "progress_resolved_count" => 21}
  end

  test "reports an unavailable catalog as unavailable instead of manufacturing an empty pack list" do
    Process.put(
      :build_orders_catalog,
      %Snapshot{
        scope: :catalog,
        repository: @repository,
        generation: :unknown,
        data: nil,
        health: ProviderHealth.new(:unknown, :unavailable, false)
      }
    )

    assert {:ok, envelope} = BuildOrdersCLI.build(source: Source, now: @captured_at)
    assert envelope["data"]["catalog"] == nil
    assert envelope["sources"]["planning_catalog"]["state"] == "unavailable"
    refute envelope["sources"]["planning_catalog"]["state"] == "empty"
  end

  test "uses the same configured data source as the Build Order LiveView" do
    previous = Application.get_env(:aiur, :build_order_data_source)
    Application.put_env(:aiur, :build_order_data_source, Source)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :build_order_data_source, previous), else: Application.delete_env(:aiur, :build_order_data_source)
    end)

    assert {:ok, envelope} = BuildOrdersCLI.build(now: @captured_at)
    assert envelope["data"]["catalog"]["entries"] |> hd() |> Map.fetch!("title") == "Build Order"
  end

  test "supports the LiveView's contextual data-source form" do
    assert {:ok, envelope} = BuildOrdersCLI.build(source: {ContextSource, :test}, now: @captured_at)
    assert envelope["data"]["catalog"]["entries"] |> hd() |> Map.fetch!("title") == "Build Order"
  end

  test "renders page-projected member completion and directed cleared versus blocking edges" do
    assert {:ok, envelope} = BuildOrdersCLI.build(root: "100", source: Source, now: @captured_at)

    assert envelope["request"] == %{"root" => "100"}
    assert Map.keys(envelope["sources"]) |> Enum.sort() == ["activity", "execution", "planning_graph"]
    assert envelope["data"]["root"]["title"] == "Build Order"

    members = Map.new(envelope["data"]["graph"]["members"], &{&1["id"], &1})
    assert members["1"]["completion"] == 100
    assert members["1"]["state"] == "closed"
    assert members["1"]["display_state"] == "merged"
    assert members["2"]["completion"] == 0
    assert members["3"]["completion"] == nil
    assert members["3"]["completion_state"] == "unresolved"
    assert members["2"]["completion_state"] == "resolved"
    assert members["3"]["blocked_by"] == [%{"from" => "2", "state" => "blocking"}]

    assert envelope["data"]["graph"]["edges"] == [
             %{"direction" => "blocker_to_blocked", "from" => "1", "state" => "cleared", "to" => "2"},
             %{"direction" => "blocker_to_blocked", "from" => "2", "state" => "blocking", "to" => "3"}
           ]

    output = capture_io(fn -> assert 0 == BuildOrdersCLI.run(root: "100", source: Source, now: @captured_at) end)
    assert output =~ "Completion: unknown"
    assert output =~ "blocked by 2 (blocking)"

    json = capture_io(fn -> assert 0 == BuildOrdersCLI.run(root: "100", json: true, source: Source, now: @captured_at) end)
    assert Jason.decode!(json)["data"]["graph"]["edges"] |> Enum.map(& &1["state"]) == ["cleared", "blocking"]
  end

  test "rejects an empty root selector before reading the source" do
    assert {:error, "accepts one non-empty Build Order root"} = BuildOrdersCLI.build(root: "", source: Source)
  end

  test "prints an invalid catalog entry without assuming it has an identity" do
    Process.put(
      :build_orders_catalog,
      %Snapshot{
        scope: :catalog,
        repository: @repository,
        generation: 7,
        data: %Catalog{entries: [%{identity: nil, title: "Invalid pack", progress: nil, member_count: nil}]},
        health: ProviderHealth.new(7, :healthy, true, observed_at: @observed_at)
      }
    )

    output = capture_io(fn -> assert 0 == BuildOrdersCLI.run(source: Source, now: @captured_at) end)
    assert output =~ "unknown: Invalid pack"
  end

  test "keeps distinct invalid members paired with their own lifecycle state" do
    health = ProviderHealth.new(7, :healthy, true, observed_at: @observed_at)

    unknown_closed = Member.new(%{identity: nil, title: "Unknown closed", state: :closed, state_reason: :completed, labels: ["phase:1"]})
    unknown_open = Member.new(%{identity: nil, title: "Unknown open", state: :open, labels: ["phase:2"]})

    Process.put(
      :build_orders_selected,
      {:ok,
       %Snapshot{
         scope: {:selected, identity(100)},
         repository: @repository,
         generation: 7,
         data: SelectedRoot.new(root(identity(100)), [unknown_closed, unknown_open], health),
         health: health
       }}
    )

    assert {:ok, envelope} = BuildOrdersCLI.build(root: "100", source: Source, now: @captured_at)

    states =
      envelope["data"]["graph"]["members"]
      |> Map.new(&{&1["title"], &1["state"]})

    assert states == %{"Unknown closed" => "closed", "Unknown open" => "open"}
  end

  defp root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order",
      url: issue_url(100),
      state: :open,
      state_reason: nil,
      labels: ["build-order"],
      member_count: 3,
      updated_at: @observed_at
    })
  end

  defp member(number, opts) do
    Member.new(%{
      identity: identity(number),
      title: "Ticket #{number}",
      url: issue_url(number),
      state: Keyword.get(opts, :state, :open),
      state_reason: Keyword.get(opts, :state_reason),
      labels: ["complexity:3", "phase:#{number}", "build-lane:runtime"],
      updated_at: @observed_at,
      dependencies: Keyword.get(opts, :dependencies, [])
    })
  end

  defp identity(number) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "ISSUE-#{number}",
      identifier: to_string(number),
      reason: nil
    }
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
