defmodule AiurWeb.ConversationResolveControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  alias Aiur.Conversation.{History, Ref, Store}
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity

  setup do
    root = Path.join(System.tmp_dir!(), "conversation-resolve-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :conversation_state_dir)
    Application.put_env(:aiur, :conversation_state_dir, root)

    Aiur.TestSupport.start_owned_endpoint!()
    AiurWeb.Endpoint.config_change([dashboard_auth_required: false], [])

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :conversation_state_dir, previous_root), else: Application.delete_env(:aiur, :conversation_state_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "resolves a healthy worker after Store.prepare despite an unreadable sibling", %{root: root} do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_issue", "number" => 1}, {"acme", "app"}, {"acme", "app"})
    {:ok, ref} = Ref.worker(identity)
    conversation_id = Ref.conversation_id(ref)
    assert {:ok, _head} = Store.prepare(Path.join(root, conversation_id), ref)

    corrupt = Path.join(root, "conv_zzzzzzzzzzzzzzzzzzzzzzzzzz")
    File.mkdir_p!(corrupt)

    test_pid = self()

    log =
      capture_log(fn ->
        conn =
          conn(
            :get,
            "/api/v1/conversations/resolve?subject=worker&owner=acme&repository=app&identifier=1"
          )
          |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
          |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))

        assert conn.status == 200
        send(test_pid, {:resolved_worker, Jason.decode!(conn.resp_body)})
      end)

    assert_received {:resolved_worker, %{"conversation_id" => ^conversation_id, "subject" => "worker"}}
    assert log =~ "skipped 1 unreadable subject.json file(s)"

    second_corrupt = Path.join(root, "conv_yyyyyyyyyyyyyyyyyyyyyyyyyy")
    File.mkdir_p!(second_corrupt)

    second_log =
      capture_log(fn ->
        conn =
          conn(
            :get,
            "/api/v1/conversations/resolve?subject=worker&owner=acme&repository=app&identifier=1"
          )
          |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
          |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))

        assert conn.status == 200
      end)

    refute second_log =~ "skipped"
  end

  test "a live worker resolves even when the durable index cannot be read", %{root: root} do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_live", "number" => 2}, {"acme", "app"}, {"acme", "app"})
    {:ok, ref} = Ref.worker(identity)
    File.write!(root, "conversation root is unreadable")
    EndpointStubs.put(conversation_units_fun: fn -> %{snapshot: %{rows: [%{identity: identity}]}} end)

    conn =
      conn(
        :get,
        "/api/v1/conversations/resolve?subject=worker&owner=acme&repository=app&identifier=2"
      )
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
      |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))

    assert conn.status == 200
    expected_id = Ref.conversation_id(ref)
    assert %{"conversation_id" => ^expected_id, "subject" => "worker"} = Jason.decode!(conn.resp_body)

    assert {:error, :unavailable} = History.resolve_worker("acme", "app", "2")
  end
end
