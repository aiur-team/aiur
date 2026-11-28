Code.require_file("../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.TicketThreadControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, Store, TestSupport}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Router
  @session Plug.Session.init(store: :cookie, key: "_thread_test", signing_salt: "test")

  setup context do
    Aiur.TestSupport.start_owned_endpoint!()
    EndpointStubs.put(conversation_executor_session_fun: fn -> %{"state" => "unknown"} end)
    context = TestSupport.setup(context)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "node-thread", "number" => 7}, {"o", "r"}, {"o", "r"})
    {:ok, worker} = Ref.worker(identity)
    EndpointStubs.put(conversation_units_fun: fn -> %{snapshot: %{rows: [%{identity: identity}]}} end)
    Map.merge(context, %{worker: worker, worker_dir: Path.join(context.root, Ref.conversation_id(worker))})
  end

  test "projects only agent and operator messages, redacted, with delivery ids and Command anchors in position order", %{worker: worker, worker_dir: dir, now: now} do
    token = "ghp_" <> String.duplicate("a", 36)

    events = [
      %{role: "assistant", msg_id: "m1", body: "starting " <> token, timestamp: now},
      %{role: "reasoning", msg_id: "r1", body: "thinking", timestamp: now},
      %{role: "user", msg_id: "operator:41", body: "please rebase", timestamp: now, payload: %{delivery_id: "41"}},
      %{role: "command", msg_id: "c1", body: "git rebase", timestamp: now, payload: %{command: "git rebase", tool_call_id: "c1"}},
      %{role: "user", msg_id: "u1", body: "provider input", timestamp: now},
      %{role: "assistant", msg_id: "m2", body: "rebased", timestamp: now}
    ]

    assert {:ok, _head} = Store.prepare(dir, worker)
    Ingest.append(worker, %{source() | role: :worker}, events)
    assert :ok = flush(worker)
    id = Ref.conversation_id(worker)
    anchor = %{"event" => %{"event_id" => 9}, "kind" => "command_requested", "precision" => "exact", "conversation_id" => id, "pos" => 4, "subject_ref" => %{"decision_id" => "dec_1"}}
    assert :ok = Store.append_anchor_line(dir, anchor)

    response = request("/7/thread")
    assert response.status == 200
    refute response.resp_body =~ token
    body = Jason.decode!(response.resp_body)
    assert %{"issue_identifier" => "7", "conversation_id" => ^id, "head_pos" => 6, "next_after" => 6} = body

    assert [
             %{"pos" => 1, "role" => "agent", "kind" => "message", "delivery_id" => nil, "text" => "starting " <> masked},
             %{"pos" => 3, "role" => "operator", "kind" => "operator_message", "text" => "please rebase", "delivery_id" => "41"},
             %{"pos" => 4, "kind" => "command", "decision_id" => "dec_1"},
             %{"pos" => 6, "role" => "agent", "kind" => "message", "text" => "rebased"}
           ] = body["entries"]

    refute masked == token
    assert is_binary(hd(body["entries"])["at"])

    first = Jason.decode!(request("/7/thread?limit=2").resp_body)
    assert Enum.map(first["entries"], &{&1["pos"], &1["kind"]}) == [{1, "message"}, {3, "operator_message"}]
    assert first["next_after"] == 3
    rest = Jason.decode!(request("/7/thread?after=3").resp_body)
    assert Enum.map(rest["entries"], & &1["pos"]) == [4, 6]
    assert Jason.decode!(request("/7/thread?after=6").resp_body)["entries"] == []

    # The current run can carry a newer display identifier than subject.json; only the Units projection knows it.
    {:worker, identity} = worker.subject
    assert_error(request("/8/thread"), 404, "thread_not_found")
    EndpointStubs.put(conversation_units_fun: fn -> %{snapshot: %{rows: [%{identity: %{identity | identifier: "8"}}]}} end)
    assert Jason.decode!(request("/8/thread").resp_body)["conversation_id"] == id
  end

  test "a ticket with no worker conversation is thread_not_found and bad parameters are typed 422s" do
    assert_error(request("/7/thread"), 404, "thread_not_found")

    for query <- ["after=x", "after=-1", "after=1.5"], do: assert_error(request("/7/thread?" <> query), 422, "invalid_cursor")
    for limit <- ["0", "201", "x"], do: assert_error(request("/7/thread?limit=" <> limit), 422, "invalid_limit")
    assert request("/7/thread", :post).status == 405
  end

  defp request(suffix, method \\ :get) do
    conn = conn(method, "/api/v1" <> suffix)
    conn = %{conn | secret_key_base: String.duplicate("s", 64), remote_ip: {127, 0, 0, 1}}
    conn = conn |> Plug.Session.call(@session) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    conn = put_req_header(conn, "authorization", "Basic " <> Base.encode64("operator:secret"))
    conn |> fetch_query_params() |> Router.call(Router.init([]))
  end

  defp assert_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["error"]["code"] == code
  end
end
