defmodule AiurWeb.BuildOrderApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Aiur.BuildOrder.Features
  alias Aiur.BuildOrder.PublishedReference
  alias Aiur.Commands.Scope
  alias AiurWeb.BuildOrderApiController

  test "returns the whole catalog document without a root selector" do
    conn = BuildOrderApiController.show(api_conn(:get), %{})

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    document = Jason.decode!(conn.resp_body)
    assert document["contract"] == "aiur.build_order"
    assert document["contract_version"] == 1
    assert document["root"]["id"] == "catalog"
    assert length(document["tickets"]) == 2
  end

  test "returns one selected root document" do
    conn = BuildOrderApiController.show(api_conn(:get), %{"root" => "7490"})

    assert conn.status == 200
    document = Jason.decode!(conn.resp_body)

    assert document["root"]["id"] == "7490"
    assert document["root"]["number"] == 7490
    assert length(document["tickets"]) == 6

    assert Enum.map(document["edges"], & &1["kind"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(contains depends_on gates serializes_with suggested_after)

    assert document["sources"]["tracker"]["status"] == "known"
  end

  test "a missing root is a 404 with the typed envelope" do
    conn = BuildOrderApiController.show(api_conn(:get), %{"root" => "999999"})

    assert conn.status == 404
    assert %{"error" => %{"code" => "build_order_not_found", "message" => message}} = Jason.decode!(conn.resp_body)
    assert message =~ "999999"
  end

  test "an unavailable projection is a 503 with the typed envelope" do
    conn =
      BuildOrderApiController.show(api_conn(:get, PublishedReference.unavailable_source()), %{"root" => "7490"})

    assert conn.status == 503

    # The source reports a typed atom; the projection seam turns it into a
    # message before the endpoint matches on it, so the envelope stays typed.
    assert %{"error" => %{"code" => "build_order_unavailable", "message" => "could not read the Build Order projection"}} =
             Jason.decode!(conn.resp_body)
  end

  test "an unavailable catalog still returns a document with unknown sources" do
    conn = BuildOrderApiController.show(api_conn(:get, PublishedReference.unavailable_catalog_source()), %{})

    assert conn.status == 200
    document = Jason.decode!(conn.resp_body)
    assert document["sources"]["tracker"]["status"] == "unknown"
    assert document["progress"]["status"] == "unknown"
  end

  test "a non-GET method is refused with an allow header" do
    conn = BuildOrderApiController.method_not_allowed(api_conn(:post), %{})

    assert conn.status == 422
    assert get_resp_header(conn, "allow") == ["GET"]
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(conn.resp_body)
  end

  test "an embedded read requires a verified feature or epic scope" do
    conn = BuildOrderApiController.embedded(api_conn(:get), %{})
    assert conn.status == 404
    assert %{"error" => %{"code" => "build_order_not_found"}} = Jason.decode!(conn.resp_body)

    {:ok, %{scope: scope}} = Scope.mint("player-7", [], secret: String.duplicate("s", 64), build_order: %{kind: "feature", key: "not-owned"})
    conn = api_conn(:get) |> Plug.Conn.assign(:command_scope, scope) |> BuildOrderApiController.embedded(%{})
    assert conn.status == 404
  end

  test "an embedded feature grant returns only its owning tickets" do
    dir = Aiur.TestSupport.tmp_root!("build-order-host-api")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    features = start_supervised!({Features, name: nil, state_dir: dir, general_epics: [], filesystem_sync_fun: fn -> :ok end, alert_fun: fn _, _, _ -> :ok end})
    meta = [server: features, source: "cli:test", actor: "test"]
    assert {:ok, _} = Features.create("game-board", %{label: "Game board"}, meta)
    assert {:ok, _} = Features.add("game-board", [8155, 9999], meta)
    assert {:ok, _} = Features.epic_create("game", %{label: "Game"}, meta)
    assert {:ok, _} = Features.epic_add("game", ["game-board"], meta)
    assert {:ok, _} = Features.create("other-game", %{label: "Other game"}, meta)
    assert {:ok, _} = Features.add("other-game", [7000], meta)
    {:ok, %{scope: scope}} = Scope.mint("creator-7", [], secret: String.duplicate("s", 64), build_order: %{kind: "feature", key: "game-board"})
    activity = %{entries: []}

    conn =
      api_conn(:get)
      |> Plug.Conn.assign(:command_scope, scope)
      |> put_private(:build_order_host_opts, features_opts: [server: features], activity_fun: fn -> activity end)
      |> BuildOrderApiController.embedded(%{})

    assert conn.status == 200
    document = Jason.decode!(conn.resp_body)
    assert [%{"key" => "game-board", "epic" => "game"}] = document["features"]
    assert document["tickets"] |> Enum.map(& &1["number"]) |> Enum.sort() == [8155, 9999]
    assert document["sources"]["pack"]["status"] == "unknown"
    assert document["waves"] == []
  end

  test "an embedded epic grant includes only its owned features and tickets" do
    dir = Aiur.TestSupport.tmp_root!("build-order-host-epic-api")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    features = start_supervised!({Features, name: nil, state_dir: dir, general_epics: [], filesystem_sync_fun: fn -> :ok end, alert_fun: fn _, _, _ -> :ok end})
    meta = [server: features, source: "cli:test", actor: "test"]
    assert {:ok, _} = Features.create("game-board", %{label: "Game board"}, meta)
    assert {:ok, _} = Features.add("game-board", [8155], meta)
    assert {:ok, _} = Features.create("unrelated", %{label: "Unrelated"}, meta)
    assert {:ok, _} = Features.add("unrelated", [7000], meta)
    assert {:ok, _} = Features.epic_create("game", %{label: "Game"}, meta)
    assert {:ok, _} = Features.epic_add("game", ["game-board"], meta)
    {:ok, %{scope: scope}} = Scope.mint("creator-7", [], secret: String.duplicate("s", 64), build_order: %{kind: "epic", key: "game"})

    conn =
      api_conn(:get)
      |> Plug.Conn.assign(:command_scope, scope)
      |> put_private(:build_order_host_opts, features_opts: [server: features], activity_fun: fn -> %{entries: []} end)
      |> BuildOrderApiController.embedded(%{})

    assert conn.status == 200
    document = Jason.decode!(conn.resp_body)
    assert [%{"key" => "game-board", "title" => "Game board", "epic" => "game"}] = document["features"]
    assert document["tickets"] |> Enum.map(& &1["number"]) == [8155]

    removed = [server: features, source: "cli:test", actor: "test"]
    assert {:ok, _} = Features.epic_remove("game", ["game-board"], removed)

    conn =
      api_conn(:get)
      |> Plug.Conn.assign(:command_scope, scope)
      |> put_private(:build_order_host_opts, features_opts: [server: features], activity_fun: fn -> %{entries: []} end)
      |> BuildOrderApiController.embedded(%{})

    assert conn.status == 404
  end

  defp api_conn(method, source \\ PublishedReference.source()) do
    method
    |> conn("/api/v1/build-order")
    |> put_private(:build_order_data_source, source)
  end
end
