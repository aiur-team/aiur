defmodule AiurWeb.BuildOrderApiControllerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Aiur.BuildOrder.PublishedReference
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

  defp api_conn(method, source \\ PublishedReference.source()) do
    method
    |> conn("/api/v1/build-order")
    |> put_private(:build_order_data_source, source)
  end
end
