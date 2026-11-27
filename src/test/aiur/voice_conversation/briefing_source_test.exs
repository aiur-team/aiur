defmodule Aiur.VoiceConversation.BriefingSourceTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.VoiceConversation.BriefingSource

  test "Executor briefing includes agent notes and build-order progress" do
    root = Aiur.TestSupport.tmp_root!("executor-briefing-source")
    :ok = Application.put_env(:aiur, :agent_status_note_root, root)
    on_exit(fn -> Application.delete_env(:aiur, :agent_status_note_root) end)
    assert {:ok, _} = Aiur.AgentStatusNote.record("42", "Working", %{"doing" => "Review the PR"}, root: root)

    health = ProviderHealth.new(1, :healthy, true)
    entry = %RootSummary{title: "Core", progress: 50, progress_resolution: :partial, member_count: 4, progress_resolved_count: 2}
    snapshot = %Snapshot{scope: :catalog, repository: {"org", "repo"}, generation: 1, health: health, data: Catalog.new([entry], health)}
    commands = [%{decision_id: "cmd-1", question: "Deploy?", decision_status: :open}]

    opts = [
      snapshot: fn -> %{running: [%{identifier: "42", title: "Fix issue", state: "in-progress"}]} end,
      status_note_root: root,
      query_decisions: fn _ -> {:ok, %{health: %{status: :available}, decisions: commands}} end,
      blocked_tickets: fn -> {:ok, MapSet.new(["45", "46"])} end,
      build_orders: fn -> snapshot end,
      read_transcript: fn _ -> {:ok, %{events: [%{role: "user", body: "Retained conversation"}]}} end
    ]

    assert {:ok, briefing} = BriefingSource.brief(:executor, opts)
    assert Enum.any?(briefing.extra, &(&1.title == "Current run agents" and &1.text =~ "Review the PR"))
    assert Enum.any?(briefing.extra, &(&1.title == "Build-order progress" and &1.text == "Core: 50% partial (2/4 resolved)"))
    refute Enum.any?(briefing.extra, &(&1.title == "Recent retained Executor transcript"))
    assert {:ok, "user: Retained conversation"} = BriefingSource.details(:executor, "transcript", opts)
    assert Enum.any?(briefing.extra, &(&1.title == "Open Commands" and &1.text == "1 open; top 1: cmd-1: Deploy?"))
    assert {:ok, "45, 46"} = BriefingSource.details(:executor, "blockers", blocked_tickets: fn -> {:ok, MapSet.new(["45", "46"])} end)

    assert {:ok, "45, org/repo#5"} =
             BriefingSource.details(:executor, "blockers", blocked_tickets: fn -> {:ok, MapSet.new(["45", {:github, "org", "repo", "5"}])} end)
  end
end
