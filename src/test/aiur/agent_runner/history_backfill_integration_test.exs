defmodule Aiur.AgentRunner.HistoryBackfillIntegrationTest do
  use ExUnit.Case, async: false
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.BuildOrder.Features
  alias Aiur.TestSupport.FeatureLabelFixture, as: F

  setup do
    assert :ok = Aiur.TestSupport.ensure_pubsub_running()
    F.setup()
  end

  defp executor(c), do: ToolExecutor.build(%Aiur.Issue{id: "77", identifier: "77"}, nil, nil, %{}, feature_opts: [server: c.features])

  test "tool reports skipped settled membership separately from successful backfill joins", c do
    assert {:ok, _} = F.join(c, 12)
    response = executor(c).("aiur_feature", %{"op" => "add", "slug" => "other", "ids" => [12, 13], "backfill" => true})
    assert response["success"]
    payload = Jason.decode!(response["output"])
    assert payload["kept"] == [12]
    assert Enum.find(payload["results"], &(&1["id"] == 12))["outcome"] == "kept_existing"
    assert Enum.find(payload["results"], &(&1["id"] == 13))["outcome"] == "added"
    assert {:ok, %{feature: "auth", confirmed: true}} = Features.owner(12, server: c.features)
    assert {:ok, %{feature: "other", confirmed: false, actor: "agent:77"}} = Features.owner(13, server: c.features)
  end

  test "export tool reads real local snapshots and a written guess leaves Unsorted", c do
    alias Aiur.BuildOrder.{EpicOverrides, History}
    alias Aiur.BuildOrder.History.Export
    name = Module.concat(__MODULE__, "Epics#{System.unique_integer([:positive])}")
    general = [%{key: "bugs", label: "Bugs", labels: ["bug"]}]
    start_supervised!({EpicOverrides, name: name, repository: "acme/widgets", state_dir: Path.join(c.dir, "epics"), settings_fun: fn -> {:ok, %{build_order: %{general_epics: general}}} end})
    assert {:ok, _} = F.observe(c, 12, [])
    assert {:ok, _} = F.observe(c, 13, ["bug"])
    assert :ok = History.mark_complete(server: c.history)

    readers = [
      now: F.now(c),
      history: fn -> History.snapshot(server: c.history) end,
      overrides: fn -> EpicOverrides.all(server: name) end,
      features: fn -> Features.snapshot(server: c.features) end,
      epics: fn -> {:ok, general} end,
      issue_body: fn _ -> :miss end
    ]

    opts = [
      repository: "acme/widgets",
      state_dir: Path.join(c.dir, "checkpoints"),
      now: F.now(c),
      catalog: fn -> EpicOverrides.catalog(server: name) end,
      features: readers[:features],
      export: fn request -> Export.page(Keyword.merge(readers, request)) end
    ]

    build = fn id -> ToolExecutor.build(%Aiur.Issue{id: id, identifier: id, labels: ["history-backfill"]}, nil, nil, %{}, history_export_opts: opts, epic_opts: [server: name]) end
    run = build.("77")
    response = run.("aiur_history_export", %{})
    assert response["success"]
    page = Jason.decode!(response["output"])
    assert Enum.map(page["rows"], & &1["number"]) == [12]
    assert hd(page["rows"])["epic"] == %{"key" => "unsorted", "source" => "default"}
    assert page["history"]["freshness"] == "current"
    assert run.("aiur_set_epic", %{"epic" => "bugs", "ids" => [12], "backfill" => true})["success"]
    assert {:ok, %{12 => %{confirmed: false, actor: "agent:77"}}, _} = EpicOverrides.all(server: name)
    response = build.("78").("aiur_history_export", %{})
    assert response["success"]
    assert Jason.decode!(response["output"])["rows"] == []
    assert Jason.decode!(response["output"])["exhausted"] == true
  end

  # Predecessor integration regression guards; these are not coverage of new production code.
  test "future regression guard: tool backfill holds labels and a human feature label wins", c do
    response = executor(c).("aiur_feature", %{"op" => "add", "slug" => "auth", "ids" => [12], "backfill" => true})
    assert response["success"]
    projection = F.start(c)
    assert F.states(projection, [12]) == {:ok, %{12 => :held_backfill}}
    assert F.calls() == []
    assert {:ok, _} = F.observe(c, 12, ["feature:other"])
    F.tick(projection)
    assert {:ok, %{feature: "other", source: "label:unknown", confirmed: true}} = Features.owner(12, server: c.features)
    assert F.calls() == []
  end
end
