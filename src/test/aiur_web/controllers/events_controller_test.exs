defmodule AiurWeb.EventsControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Aiur.Events.{Catalog, Export}
  alias Aiur.Events.Export.Exporter

  setup do
    root = Path.join(System.tmp_dir!(), "events-api-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :runtime_state_dir)
    previous_status = :persistent_term.get({Export, :status}, :missing)
    Application.put_env(:aiur, :runtime_state_dir, root)

    on_exit(fn ->
      Application.put_env(:aiur, :runtime_state_dir, previous_root)
      if previous_status == :missing, do: :persistent_term.erase({Export, :status}), else: :persistent_term.put({Export, :status}, previous_status)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    opts = [name: nil, identity: fn -> {:ok, "test/instance"} end, subscribe: fn _ -> :ok end]
    pid = start_supervised!({Exporter, opts})
    :sys.get_state(pid)
    for id <- 2..5, do: send(pid, {:event, %{id: id, topic: "ticket.42.pr.merged", body: "private text"}})
    :sys.get_state(pid)
    stop_supervised!(Exporter)
    pid = start_supervised!({Exporter, opts})
    :sys.get_state(pid)
    for id <- 7..10, do: send(pid, {:event, %{id: id, topic: "ticket.43.pr.merged"}})
    assert :sys.get_state(pid).head_seq == 10
    {:ok, root: root}
  end

  test "returns 404 feature_disabled when export is off" do
    :persistent_term.erase({Export, :status})

    for path <- ["/api/v1/events", "/api/v1/events/catalog"] do
      assert %{"error" => %{"code" => "feature_disabled", "message" => "event export is disabled (events.export.enabled: false)"}} = request(path, 404)
    end
  end

  test "GET /api/v1/events is not shadowed and omitted cursor starts at head" do
    result = request("/api/v1/events", 200)
    assert result == %{"head_seq" => 10, "oldest_seq" => 1, "instance" => "test/instance", "epoch" => Export.status().epoch, "records" => []}
  end

  test "catalog route is reachable and exposes only public fields" do
    expected = Enum.map(Catalog.exported(), &(Map.take(&1, [:pattern, :class, :payload_version]) |> Jason.encode!() |> Jason.decode!()))
    assert request("/api/v1/events/catalog", 200) == %{"v" => 1, "topics" => expected}
  end

  test "resume returns exactly the records after seq" do
    result = request("/api/v1/events?after=4&limit=3", 200)
    assert Enum.map(result["records"], & &1["seq"]) == [5, 6, 7]
    assert result["head_seq"] == 10
    refute Jason.encode!(result) =~ "private text"
  end

  test "a cursor older than retention returns one reset record" do
    # Reader projection fixture; exporter retention has separate coverage.
    :persistent_term.put({Export, :status}, %{Export.status() | oldest_seq: 5})
    result = request("/api/v1/events?after=3", 200)
    assert result["records"] == [%{"type" => "reset", "oldest_seq" => 5, "head_seq" => 10}]
    assert result["instance"] == "test/instance"
  end

  test "epoch mismatch and cursor beyond head return only reset" do
    for query <- ["after=4&epoch=old", "after=11"] do
      result = request("/api/v1/events?#{query}", 200)
      assert result["records"] == [%{"type" => "reset", "oldest_seq" => 1, "head_seq" => 10}]
      assert result["epoch"] == Export.status().epoch
    end
  end

  test "gap records survive a narrowed topic filter" do
    result = request("/api/v1/events?after=4&topics=ticket.43.pr.merged", 200)
    assert Enum.map(result["records"], & &1["seq"]) == [6, 7, 8, 9, 10]
    assert hd(result["records"])["type"] == "gap"
    assert hd(result["records"])["scope"] == "*"
  end

  test "exported wildcards and comma separated narrower patterns are accepted" do
    assert Enum.map(request("/api/v1/events?after=6&topics=ticket.*.pr.merged", 200)["records"], & &1["seq"]) == [7, 8, 9, 10]
    assert Enum.map(request("/api/v1/events?after=1&topics=ticket.42.pr.merged,ticket.43.pr.merged", 200)["records"], & &1["seq"]) == Enum.to_list(2..10)
  end

  test "a non-exported or malformed topic filter is 422" do
    for topic <- ["ticket.*.agent.custom.#", "#", "ticket.#.pr.merged", "ticket..pr.merged", "ticket.x*.pr.merged", "", "ticket.42.pr.merged,"] do
      assert %{"error" => %{"code" => "topic_not_exported"}} = request("/api/v1/events?topics=#{URI.encode_www_form(topic)}", 422)
    end

    assert %{"error" => %{"code" => "topic_not_exported"}} = request("/api/v1/events?topics[]=ticket.42.pr.merged", 422)
  end

  # Future regression guard: the existing API auth policy must protect these new routes too.
  test "unauthenticated request gets no event content" do
    for path <- ["/api/v1/events", "/api/v1/events/catalog"] do
      response = call(path, :get, "wrong")
      assert response.status == 401
      refute response.resp_body =~ "records"
      refute response.resp_body =~ "topics"
    end
  end

  test "limit outside 1..500 or malformed is 422" do
    for value <- ["0", "501", "-1", "1.2", "oops", "", "+1"] do
      assert %{"error" => %{"code" => "invalid_limit"}} = request("/api/v1/events?limit=#{URI.encode_www_form(value)}", 422)
    end

    assert request("/api/v1/events?limit=500&after=10", 200)["records"] == []
  end

  test "invalid cursor shapes are 422" do
    for query <- ["after=-1", "after=1x", "after=", "after[]=1", "epoch[]=old", "limit[]=1"] do
      assert %{"error" => %{"code" => code}} = request("/api/v1/events?#{query}", 422)
      assert code == if(String.starts_with?(query, "limit"), do: "invalid_limit", else: "invalid_cursor")
    end
  end

  test "corrupt journal is 503 events_unavailable", %{root: root} do
    File.write!(Path.join(root, "events/export/seg.1.ndjson"), "{broken\n")
    assert %{"error" => %{"code" => "events_unavailable"}} = request("/api/v1/events?after=0", 503)
  end

  test "unavailable exporter is 503 rather than an empty successful feed" do
    :persistent_term.put({Export, :status}, %{Export.status() | state: :unavailable, reason: :append_failed, head_seq: nil})
    assert %{"error" => %{"code" => "events_unavailable"}} = request("/api/v1/events", 503)
  end

  test "other methods are rejected before generic issue routes" do
    for path <- ["/api/v1/events", "/api/v1/events/catalog"], method <- [:post, :put, :delete] do
      response = call(path, method)
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  defp request(path, status) do
    response = call(path)
    assert response.status == status
    assert get_resp_header(response, "cache-control") == ["no-store"]
    Jason.decode!(response.resp_body)
  end

  defp call(path, method \\ :get, password \\ "test-dashboard-secret") do
    conn(method, path)
    |> fetch_query_params()
    |> init_test_session(%{})
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:#{password}"))
    |> AiurWeb.Router.call(AiurWeb.Router.init([]))
  end
end
