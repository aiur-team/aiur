defmodule Aiur.AgentTools.FeatureTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentTools.Dispatch
  alias Aiur.AgentTools.Feature
  alias Aiur.BuildOrder.Features

  setup do
    dir = Aiur.TestSupport.tmp_root!("feature-tool")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({Features, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, general_epics: [], alert_fun: fn _, _, _ -> :ok end})
    {:ok, _} = Features.create("app", %{label: "App"}, server: store, actor: "cli:tester", source: "cli:tester")
    %{store: store}
  end

  test "V-T1 rejects actor, source and unknown fields before the writer" do
    for field <- ["actor", "source", "confirmed", "unexpected"] do
      args = Map.put(%{"op" => "add", "slug" => "app", "ids" => [12]}, field, "cli:kevin")
      response = Dispatch.execute("aiur_feature", args, feature_writer: fn _ -> flunk("writer called") end)
      assert response["success"] == false
      assert payload(response)["error"]["code"] == "invalid_feature_arguments"
    end
  end

  test "V-T2 refuses operator scope controls and backfill operations other than add" do
    for op <- ["baseline", "edit"] do
      response = Dispatch.execute("aiur_feature", %{"op" => op, "slug" => "app"}, feature_writer: fn _ -> flunk("writer called") end)
      assert payload(response)["error"]["code"] == "agent_cannot_use_feature_op"
      assert response["success"] == false
    end

    for op <- ["create", "also", "remove", "show"] do
      response = Dispatch.execute("aiur_feature", %{"op" => op, "slug" => "app", "backfill" => true}, feature_writer: fn _ -> flunk("writer called") end)
      assert payload(response)["error"]["code"] == "backfill_cannot_use_feature_op"
      assert response["success"] == false
    end
  end

  test "V-T3 no writer returns unavailable rather than success" do
    response = Dispatch.execute("aiur_feature", %{"op" => "show", "slug" => "app"})
    assert response["success"] == false
    assert payload(response)["error"]["code"] == "feature_writer_unavailable"
  end

  test "normalizer enforces types, per-operation fields and batch bounds" do
    for args <- [
          nil,
          %{},
          %{"op" => "delete"},
          %{"op" => "add", "slug" => "app", "ids" => []},
          %{"op" => "add", "slug" => "app", "ids" => ["12"]},
          %{"op" => "add", "slug" => "app", "ids" => [2_147_483_648]},
          %{"op" => "add", "slug" => "app", "ids" => Enum.to_list(1..201)},
          %{"op" => "add", "slug" => "app", "ids" => [12], "move" => "yes"},
          %{"op" => "add", "slug" => "app", "ids" => [12], "hue" => 1},
          %{"op" => "create", "slug" => "app", "label" => ""},
          %{"op" => "create", "slug" => "app", "label" => "App", "hue" => 360},
          %{"op" => "create", "slug" => "app", "label" => "App", "epics" => [%{"key" => "f-app", "label" => "App", "actor" => "forged"}]}
        ] do
      assert {:error, :invalid_feature_arguments} = Feature.normalize(args)
    end

    assert {:ok, %{op: :add, ids: [12, 13]}} = Feature.normalize(%{"op" => "add", "slug" => "app", "ids" => [12, 12, 13]})
    assert hd(Feature.specs())["inputSchema"]["additionalProperties"] == false
  end

  test "V-T4 real executor records the bound issue number, never its node id", %{store: store} do
    run = executor("77", store)
    result = run.("aiur_feature", %{"op" => "add", "slug" => "app", "ids" => [12]})
    assert result["success"] == true
    assert payload(result)["command"] == "feature add"
    assert {:ok, %{owners: %{12 => %{actor: "agent:77", source: "agent:77", confirmed: true}}}} = Features.snapshot(server: store)
    assert {:ok, before} = Features.journal("app", server: store)

    for identifier <- ["ABC-12", nil, "0", "2147483648", "77\n"] do
      response = executor(identifier, store).("aiur_feature", %{"op" => "add", "slug" => "app", "ids" => [13]})
      assert response["success"] == false
      assert payload(response)["error"]["code"] == "feature_tool_needs_github_issue"
      assert {:ok, ^before} = Features.journal("app", server: store)
    end
  end

  test "V-T2 backfill add records unconfirmed source with bound actor", %{store: store} do
    result = executor("77", store).("aiur_feature", %{"op" => "add", "slug" => "app", "ids" => [12], "backfill" => true})
    assert result["success"] == true
    assert {:ok, %{owners: %{12 => %{actor: "agent:77", source: "backfill-agent", confirmed: false}}}} = Features.snapshot(server: store)
  end

  test "tool create, also, show and remove share the registry operation path", %{store: store} do
    run = executor("77", store)
    created = run.("aiur_feature", %{"op" => "create", "slug" => "other", "label" => "Other", "hue" => 120, "epics" => [%{"key" => "f-other", "label" => "Other work"}]})
    assert created["success"] == true
    assert payload(created)["outcome"] == "created"
    assert {:ok, %{features: %{"other" => %{label: "Other", hue: 120, epics: [%{key: "f-other", label: "Other work"}]}}}} = Features.snapshot(server: store)
    assert run.("aiur_feature", %{"op" => "add", "slug" => "app", "ids" => [12]})["success"]
    assert run.("aiur_feature", %{"op" => "also", "slug" => "other", "ids" => [12]})["success"]
    shown = run.("aiur_feature", %{"op" => "show", "slug" => "other"})
    assert shown["success"] == true
    assert payload(shown)["feature"]["key"] == "other"
    assert payload(shown)["also"] == [12]
    removed = run.("aiur_feature", %{"op" => "remove", "slug" => "app", "ids" => [12]})
    assert removed["success"] == true
    assert payload(removed)["results"] == [%{"id" => 12, "outcome" => "removed"}]
    assert {:ok, %{owners: owners}} = Features.snapshot(server: store)
    refute Map.has_key?(owners, 12)
  end

  defp executor(identifier, store), do: ToolExecutor.build(%Aiur.Issue{id: "gid-te-feat", identifier: identifier}, nil, nil, %{}, feature_opts: [server: store])
  defp payload(response), do: Jason.decode!(response["output"])
end
