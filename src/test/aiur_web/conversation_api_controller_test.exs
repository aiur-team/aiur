Code.require_file("../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, Store, TestSupport}
  alias AiurWeb.{ConversationApiController, Router}
  @session Plug.Session.init(store: :cookie, key: "_conversation_test", signing_salt: "test")

  setup context do
    Aiur.TestSupport.start_owned_endpoint!()

    Aiur.TestSupport.EndpointStubs.put(
      conversation_executor_session_fun: fn -> %{"state" => "unknown"} end,
      conversation_units_fun: fn -> %{snapshot: %{rows: []}} end
    )

    TestSupport.setup(context)
  end

  test "GET entries tail returns positions and cursors without caching", %{ref: ref} do
    Ingest.append(ref, source(), Enum.map(1..3, &event/1))
    assert :ok = flush(ref)
    conn = request("/#{Ref.conversation_id(ref)}/entries?tail=true&limit=2")
    assert conn.status == 200
    page = Jason.decode!(conn.resp_body)
    assert Enum.map(page["entries"], & &1["pos"]) == [2, 3]
    assert page["prev_cursor"] == 2
    assert page["next_cursor"] == nil
    assert page["head_pos"] == 3
    assert [%{"session_seq" => 1, "first_pos" => 1}] = page["sessions"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert request("/#{Ref.conversation_id(ref)}/entries?before=2").resp_body |> Jason.decode!() |> Map.get("entries") |> Enum.map(& &1["pos"]) == [1]
  end

  test "invalid parameters fail with distinct validation errors" do
    for query <- ["before=1&after=2", "before=-1", "around=0", "tail=false", "after=x", "before[]=1"] do
      assert_error(request("/x/entries?" <> query), 422, "invalid_cursor")
    end

    for limit <- ["0", "201", "1x", "-1"] do
      assert_error(request("/x/entries?limit=" <> limit), 422, "invalid_limit")
    end

    assert_error(request("/x/anchors?pos_from=3&pos_to=2"), 422, "invalid_range")
    assert_error(request("/resolve?subject=worker"), 422, "invalid_subject")
  end

  test "unknown and empty are distinct and corrupt storage is unavailable", %{ref: ref, dir: dir} do
    assert_error(request("/x/entries"), 404, "conversation_not_found")
    assert {:ok, _} = Store.prepare(dir, ref)
    empty = request("/#{Ref.conversation_id(ref)}/entries")
    assert empty.status == 200
    assert %{"entries" => [], "head_pos" => 0} = Jason.decode!(empty.resp_body)
    File.write!(Path.join(dir, "head.json"), "broken")
    assert_error(request("/#{Ref.conversation_id(ref)}/entries"), 503, "conversation_unavailable")
  end

  test "namespace is reserved and write verbs are refused" do
    assert_error(request(""), 404, "conversation_not_found")
    assert_error(request("/x/entries", :post), 405, "method_not_allowed")
    assert get_resp_header(request("/x/entries", :post), "allow") == ["GET, HEAD"]
  end

  test "all reads require dashboard authentication" do
    for suffix <- ["", "/resolve?subject=executor", "/x/entries", "/x/sessions", "/x/anchors"] do
      conn = request(suffix, :get, false)
      assert conn.status == 401
    end
  end

  test "executor resolution requires a stored conversation", %{ref: ref, dir: dir} do
    assert_error(request("/resolve?subject=executor"), 404, "subject_not_found")
    assert {:ok, _} = Store.prepare(dir, ref)
    assert_error(request("/resolve?subject=executor"), 404, "subject_not_found")
    Aiur.TestSupport.EndpointStubs.put(conversation_executor_session_fun: fn -> %{"state" => "live"} end)
    response = request("/resolve?subject=executor")
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"conversation_id" => Ref.conversation_id(ref), "subject" => "executor"}
  end

  test "worker resolution loads historical subjects and updates a warm index", %{root: root} do
    assert_error(request("/resolve?subject=worker&owner=o&repository=r&identifier=7"), 404, "subject_not_found")
    ref = worker("node-one")
    assert {:ok, _} = Store.prepare(Path.join(root, Ref.conversation_id(ref)), ref)
    response = request("/resolve?subject=worker&owner=O&repository=R&identifier=7")
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["conversation_id"] == Ref.conversation_id(ref)
    {:worker, identity} = ref.subject
    current = %{identity | identifier: "8"}
    Aiur.TestSupport.EndpointStubs.put(conversation_units_fun: fn -> %{snapshot: %{rows: [%{identity: current}]}} end)
    renamed = request("/resolve?subject=worker&owner=o&repository=r&identifier=8")
    assert renamed.status == 200
    assert Jason.decode!(renamed.resp_body)["conversation_id"] == Ref.conversation_id(ref)
    assert_error(request("/resolve?subject=worker&owner=elsewhere&repository=r&identifier=8"), 404, "subject_not_found")
    :ets.delete_all_objects(:aiur_conversation_subjects)
    assert request("/resolve?subject=worker&owner=o&repository=r&identifier=7").status == 200
    other = worker("node-two")
    assert {:ok, _} = Store.prepare(Path.join(root, Ref.conversation_id(other)), other)
    ambiguous = request("/resolve?subject=worker&owner=o&repository=r&identifier=7")
    assert_error(ambiguous, 409, "ambiguous_subject")
    assert Jason.decode!(ambiguous.resp_body)["error"]["conversation_ids"] == Enum.sort([Ref.conversation_id(ref), Ref.conversation_id(other)])
  end

  test "sessions and strongest filtered anchors are serialized", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    id = Ref.conversation_id(ref)
    sessions = request("/#{id}/sessions")
    assert sessions.status == 200
    assert [%{"harness" => "codex", "first_pos" => 1}] = Jason.decode!(sessions.resp_body)["sessions"]
    anchor = %{"event" => %{"event_id" => 1}, "kind" => "progress", "precision" => "observed", "conversation_id" => id, "pos" => 1}
    assert :ok = Store.append_anchor_line(dir, anchor)
    exact = Map.put(anchor, "precision", "exact")
    assert :ok = Store.append_anchor_line(dir, exact)
    unanchored = %{anchor | "event" => %{"event_id" => 2}, "precision" => "unanchored", "pos" => nil}
    assert :ok = Store.append_anchor_line(dir, unanchored)
    assert Jason.decode!(request("/#{id}/anchors").resp_body) == %{"anchors" => [exact, unanchored]}
    response = request("/#{id}/anchors?kinds=progress&pos_from=1&pos_to=1")
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"anchors" => [exact]}
    assert Jason.decode!(request("/#{id}/anchors?pos_from=2").resp_body) == %{"anchors" => []}
  end

  test "reveal depends on the connection principal, never query parameters", %{ref: ref} do
    token = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ref, source(), [Map.put(event(1), :body, token)])
    assert :ok = flush(ref)
    path = "/#{Ref.conversation_id(ref)}/entries?reveal=true&principal=internal"
    local = request(path)
    assert local.resp_body =~ token
    remote = request(path, :get, true, {192, 0, 2, 1})
    refute remote.resp_body =~ token
    assert hd(Jason.decode!(remote.resp_body)["entries"])["redacted"] == true
    conn = conn(:get, "/") |> assign(:device_id, "device-one") |> fetch_query_params()
    params = %{"conversation_id" => Ref.conversation_id(ref), "reveal" => "true"}
    device = ConversationApiController.call(%{conn | params: params}, ConversationApiController.init(:entries))
    refute device.resp_body =~ token
    assert hd(Jason.decode!(device.resp_body)["entries"])["redacted"] == true
  end

  test "public binds reject Basic and read bearer tokens remain masked on loopback", %{root: root, ref: ref} do
    path = Path.join(root, "client-tokens.json")
    previous = Application.fetch_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :client_tokens_path, value)
        :error -> Application.delete_env(:aiur, :client_tokens_path)
      end
    end)

    {:ok, bearer} = Aiur.ClientTokens.create("conversation-reader", "read")
    token = "ghp_" <> String.duplicate("b", 36)
    Ingest.append(ref, source(), [Map.put(event(1), :body, token)])
    assert :ok = flush(ref)
    Aiur.TestSupport.EndpointStubs.put(public_bind: true)
    suffix = "/#{Ref.conversation_id(ref)}/entries?reveal=true"
    assert request(suffix).status == 401
    response = request(suffix, :get, bearer)
    assert response.status == 200
    refute response.resp_body =~ token
    assert hd(Jason.decode!(response.resp_body)["entries"])["redacted"] == true
  end

  defp worker(provider_id) do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => provider_id, "number" => 7}, {"o", "r"}, {"o", "r"})
    {:ok, ref} = Ref.worker(identity)
    ref
  end

  defp request(suffix, method \\ :get, auth? \\ true, ip \\ {127, 0, 0, 1}) do
    conn = conn(method, "/api/v1/conversations" <> suffix)
    conn = %{conn | secret_key_base: String.duplicate("s", 64), remote_ip: ip}
    conn = conn |> Plug.Session.call(@session) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})

    conn =
      case auth? do
        true -> put_req_header(conn, "authorization", "Basic " <> Base.encode64("operator:secret"))
        false -> conn
        token when is_binary(token) -> put_req_header(conn, "authorization", "Bearer " <> token)
      end

    conn |> fetch_query_params() |> Router.call(Router.init([]))
  end

  defp assert_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["error"]["code"] == code
  end
end
