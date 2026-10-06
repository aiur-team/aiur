defmodule Aiur.AgentContextPresentationTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentContextPresentation, as: Context
  alias Aiur.AgentList.Renderer.{Layout, Table, Text}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{State, StatusReport}

  test "unknown window stays explicit in both formats" do
    usage = %{used_tokens: 150, window_tokens: nil, used_percent: nil, pressure: :warning}
    assert Context.label(usage) == "150 tokens / unknown capacity · warning"
    assert Context.compact(usage) == "150/? ctx"
    assert Context.label(nil) == "—"
    assert Context.compact(nil) == "—"
  end

  test "known window renders actual occupancy" do
    usage = %{used_tokens: 150, window_tokens: 300, used_percent: 50.0, pressure: :normal}
    assert Context.label(usage) == "150 / 300 tokens (50%)"
    assert Context.compact(usage) == "50% 150/300"
    assert Context.compact(%{used_tokens: 1_000, window_tokens: 1_000}) == "100% ctx"
  end

  test "agent-list row renders context only when present and wide enough" do
    summary = %{identifier: "MUSE-1", title: "Working", status: :running, context_usage: %{used_tokens: 150, window_tokens: nil, pressure: :normal}}
    wide = Layout.compute([summary], 140)
    assert wide.show_context?
    assert Table.table_header_row(140, wide) |> IO.iodata_to_binary() =~ "CTX"

    row = Table.render_row(summary, false, 140, wide, %{}) |> IO.iodata_to_binary()
    assert row =~ "150/? ctx"
    assert Text.visual_width(Text.strip_ansi(row)) in 139..140

    narrow = Layout.compute([summary], 60)
    refute narrow.show_context?
    refute Table.render_row(summary, false, 60, narrow, %{}) |> IO.iodata_to_binary() =~ "150/? ctx"
  end

  test "orchestrator running summaries carry the observed context to the board" do
    context = %{used_tokens: 150, window_tokens: nil, used_percent: nil, pressure: :warning}
    issue = %Issue{id: "issue-1", identifier: "MUSE-1", title: "Working", state: "in-progress"}
    entry = %{identifier: issue.identifier, issue: issue, context_usage: context, control: %{status: :working}}
    state = %State{candidate_snapshot_fresh?: false, running: %{issue.id => entry}}

    assert [%{identifier: "MUSE-1", context_usage: ^context}] = StatusReport.running_summaries(state)
  end
end
