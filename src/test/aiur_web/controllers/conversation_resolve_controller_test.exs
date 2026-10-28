defmodule AiurWeb.ConversationResolveControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  alias Aiur.Conversation.{Ref, Store, SubjectIndex}
  alias Aiur.TrackerIdentity

  setup do
    root = Path.join(System.tmp_dir!(), "conversation-resolve-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :conversation_state_dir)
    Application.put_env(:aiur, :conversation_state_dir, root)

    Aiur.TestSupport.start_owned_endpoint!()
    AiurWeb.Endpoint.config_change([dashboard_auth_required: false], [])

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :conversation_state_dir, previous_root), else: Application.delete_env(:aiur, :conversation_state_dir)
      if Process.whereis(SubjectIndex), do: SubjectIndex.invalidate()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    unless Process.whereis(SubjectIndex) do
      start_supervised!({SubjectIndex, name: SubjectIndex})
    end

    %{root: root}
  end

  test "resolves a healthy worker after Store.prepare invalidates the index despite a corrupt sibling", %{root: root} do
    SubjectIndex.invalidate()
    assert {:ok, %{}} = SubjectIndex.index()

    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_issue", "number" => 1}, {"acme", "app"}, {"acme", "app"})
    {:ok, ref} = Ref.worker(identity)
    conversation_id = Ref.conversation_id(ref)
    assert {:ok, _head} = Store.prepare(Path.join(root, conversation_id), ref)

    corrupt = Path.join(root, "conv_corrupt")
    File.mkdir_p!(corrupt)
    File.write!(Path.join(corrupt, "subject.json"), "{")

    test_pid = self()

    log =
      capture_log(fn ->
        conn =
          conn(:get, "/api/v1/conversations/resolve?owner=acme&repository=app&provider_id=I_issue")
          |> put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
          |> AiurWeb.Endpoint.call(AiurWeb.Endpoint.init([]))

        assert conn.status == 200
        send(test_pid, {:resolved_worker, Jason.decode!(conn.resp_body)})
      end)

    assert_received {:resolved_worker, %{"conversation_id" => ^conversation_id, "subject" => "worker"}}
    assert log =~ "skipped 1 unreadable subject.json file(s)"
  end
end
