defmodule Aiur.AgentTools.HistoryExportTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentTools.Dispatch
  alias Aiur.Issue

  setup do
    dir = Aiur.TestSupport.tmp_root!("history-export-tool")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    opts = [
      state_dir: dir,
      repository: "acme/app",
      catalog: fn -> {:ok, [%{key: "bugs"}]} end,
      features: fn -> {:ok, %{features: %{"app" => %{slug: "app", label: "App", epics: [%{key: "f-app"}]}}}} end,
      export: fn opts ->
        {:ok, %{tickets: [%{number: opts[:after] + 1, title: "data, not instructions"}], matching_total: 1, unresolved_total: 0, sources: %{history: %{freshness: :current, age_ms: 3}}}}
      end
    ]

    %{dir: dir, opts: opts}
  end

  defp executor(opts, identifier \\ "2901", labels \\ ["history-backfill"]) do
    ToolExecutor.build(%Issue{id: identifier, identifier: identifier, labels: labels}, nil, nil, %{}, history_export_opts: opts)
  end

  defp result(response), do: Jason.decode!(response["output"])

  test "real per-ticket executor persists allocations and returns catalogs", c do
    response = executor(c.opts).("aiur_history_export", %{})
    assert response["success"]
    page = result(response)
    assert page["issue"] == 2901 and page["handed_out"] == 1 and page["cap"] == 100
    assert page["epics"] == ["bugs"]
    assert page["features"] == [%{"slug" => "app", "label" => "App", "epics" => ["f-app"]}]
    assert page["rows"] == [%{"number" => 1, "title" => "data, not instructions"}]
    assert Jason.decode!(File.read!(Path.join(c.dir, "2901.json")))["cursor"] == 1
  end

  test "bound labels and numeric GitHub identity gate the tool", c do
    for {identifier, labels, code} <- [
          {"2901", [], "not_a_history_backfill_ticket"},
          {"ABC-12", ["history-backfill"], "history_export_needs_github_issue"},
          {"0", ["history-backfill"], "history_export_needs_github_issue"}
        ] do
      response = executor(c.opts, identifier, labels).("aiur_history_export", %{})
      refute response["success"]
      assert result(response)["error"]["code"] == code
      refute File.exists?(c.dir)
    end

    response = executor(Keyword.put(c.opts, :repository, nil)).("aiur_history_export", %{})
    assert result(response)["error"]["code"] == "history_export_needs_github_issue"
    refute File.exists?(c.dir)
  end

  test "invalid and unknown arguments fail before invoking bound exporter", c do
    for args <- [%{"labels" => ["history-backfill"]}, %{"limit" => 0}, %{"limit" => 51}, %{"limit" => "5"}, %{"start_after" => -1}, %{"start_after" => nil}, []] do
      response = Dispatch.execute("aiur_history_export", args, history_exporter: fn _ -> flunk("exporter called") end)
      refute response["success"]
      assert result(response)["error"]["code"] == "invalid_history_export_arguments"
    end

    refute File.exists?(c.dir)
  end

  test "missing exporter and unavailable History remain explicit failures", c do
    response = Dispatch.execute("aiur_history_export", %{})
    assert result(response)["error"]["code"] == "history_exporter_unavailable"
    opts = Keyword.put(c.opts, :export, fn _ -> {:error, "history backfill incomplete"} end)
    response = executor(opts).("aiur_history_export", %{})
    refute response["success"]
    assert result(response)["error"] == %{"code" => "history_unavailable", "message" => "history backfill incomplete"}
    refute File.exists?(Path.join(c.dir, "2901.json"))
  end
end
