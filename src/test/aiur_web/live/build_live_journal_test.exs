Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.BuildLiveJournalTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}

  setup context do
    context = TestSupport.setup(context)
    root = Aiur.TestSupport.tmp_root!("build-journal")
    Aiur.TestSupport.write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    row = Enum.find(data()["sections"]["now"], &(&1["agent"] != nil and &1["start"] != nil))
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "node-#{row["id"]}", "number" => row["id"]}, {"owner", "aiur"}, {"owner", "aiur"})
    {:ok, worker} = Ref.worker(identity)
    running = %{identifier: row["id"], issue_id: identity.provider_id, tracker_identity: identity, workspace_path: Path.join(root, "missing")}
    EndpointStubs.put(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end, build_events_log_fun: fn _, _ -> {:ok, []} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    Map.merge(context, %{worker: worker, id: row["id"]})
  end

  test "desktop modal reads and polls journal appends with no workspace file", %{worker: worker, id: id} do
    append(worker, 1)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "conversation-page", %{id: id})
    assert_reply(view, reply)
    assert [%{"text" => "message 1", "k" => "say"}] = Enum.filter(reply["entries"], &(&1["k"] == "say"))
    assert reply["state"] == "live"
    assigns = :sys.get_state(view.pid).socket.assigns
    refute File.exists?(assigns.conversation_ref.path)
    append(worker, 2)
    send(view.pid, {:build_conversation_poll, assigns.conversation_poll_token})
    assert_push_event(view, "build-conversation", %{"kind" => "conversation-append", "entries" => [%{"k" => "say", "text" => "message 2"}]})
    render_hook(view, "conversation-close", %{id: id})
  end

  defp append(worker, n) do
    Ingest.append(worker, source(), [event(n)])
    assert :ok = flush(worker)
  end
end
