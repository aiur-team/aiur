defmodule Aiur.VoiceConversation.BriefingSourceTest do
  use Aiur.TestSupport

  alias Aiur.VoiceConversation.BriefingSource

  test "Executor briefing includes agent notes and build-order progress" do
    root = Aiur.TestSupport.tmp_root!("executor-briefing-source")
    :ok = Application.put_env(:aiur, :agent_status_note_root, root)
    on_exit(fn -> Application.delete_env(:aiur, :agent_status_note_root) end)
    assert {:ok, _} = Aiur.AgentStatusNote.record("42", "Working", %{"doing" => "Review the PR"}, root: root)

    catalog_document = %{"epics" => [%{"title" => "Core"}], "progress" => %{"percent" => 50}, "edges" => []}
    commands = [%{decision_id: "cmd-1", question: "Deploy?", decision_status: :open}]

    opts = [
      snapshot: fn -> %{running: [%{identifier: "42", title: "Fix issue", state: "in-progress"}]} end,
      status_note_root: root,
      query_decisions: fn _ -> {:ok, %{health: %{status: :available}, decisions: commands}} end,
      blocked_tickets: fn -> {:ok, MapSet.new(["45", "46"])} end,
      build_orders: fn -> {:ok, %{data: %{catalog: catalog_document}}} end,
      read_transcript: fn _ -> {:error, :unavailable} end
    ]

    assert {:ok, briefing} = BriefingSource.brief(:executor, opts)
    assert Enum.any?(briefing.extra, &(&1.title == "Current run agents" and &1.text =~ "Review the PR"))
    assert Enum.any?(briefing.extra, &(&1.title == "Build-order progress and blockers" and &1.text =~ "Core: 50%"))
    assert Enum.any?(briefing.extra, &(&1.title == "Open Commands" and &1.text == "1 open; top 1: cmd-1: Deploy?"))
    assert {:ok, "45, 46"} = BriefingSource.details(:executor, "blockers", blocked_tickets: fn -> {:ok, MapSet.new(["45", "46"])} end)
  end
end
