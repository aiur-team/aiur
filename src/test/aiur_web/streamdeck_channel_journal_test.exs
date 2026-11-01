Code.require_file("../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.StreamdeckChannelJournalTest do
  use Aiur.TestSupport
  use AiurWeb.StreamdeckChannelCase
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias Aiur.TestSupport.EndpointStubs

  setup context do
    context = TestSupport.setup(context)
    root = Aiur.TestSupport.tmp_root!("channel-journal")
    Aiur.TestSupport.write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "node-seven", "number" => 7}, {"owner", "aiur"}, {"owner", "aiur"})
    {:ok, worker} = Ref.worker(identity)
    running = %{identifier: "7", issue_id: "node-seven", tracker_identity: identity, workspace_path: Path.join(root, "missing")}
    EndpointStubs.put(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    Map.put(context, :worker, worker)
  end

  test "focused deck pushes journal transcript and polls new entries without workspace logs", %{worker: worker} do
    Ingest.append(worker, source(), [event(1)])
    assert :ok = flush(worker)
    socket = joined_socket()
    assert_reply(push(socket, "focus", %{"identifier" => "7"}), :ok, %{"focused" => "7"})
    assert_push("chat", %{"id" => "7", "state" => "live", "latest" => %{"k" => "say", "text" => "message 1"}}, 2_000)
    Ingest.append(worker, source(), [event(2)])
    assert :ok = flush(worker)
    assert_push("chat", %{"latest" => %{"text" => "message 2"}}, 2_000)
    assert_reply(push(socket, "unfocus", %{}), :ok, _reply)
  end
end
