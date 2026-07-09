defmodule Aiur.AgentList.Renderer.EventLineTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.EventLine

  test "self agent receive echoes are suppressed, but self issue comments survive" do
    assert EventLine.format_event_line(
             %{kind: :receive, topic: "ticket.140.agent.phase.work.start", identifier: "140"},
             "140",
             nil
           ) == nil

    assert EventLine.format_event_line(
             %{
               kind: :receive,
               topic: "ticket.140.issue.commented",
               identifier: "140",
               body: %{"comment" => %{"body" => "hello"}}
             },
             "140",
             nil
           ) == "📬 140 new Issue comment: \"hello\""
  end

  test "cross-ticket receive renders source arrow phrasing" do
    assert EventLine.format_event_line(
             %{kind: :receive, topic: "ticket.99.branch.push", identifier: "830"},
             "830",
             nil
           ) == "📬 830 ← 99: pushed"
  end

  test "publish renders glyph, subject id, and verb" do
    assert EventLine.format_event_line(
             %{kind: :publish, topic: "ticket.830.issue.commented", body: %{}},
             "830",
             nil
           ) == "💬 830 got an issue comment:"
  end

  test "read from another ticket renders ingested source" do
    assert EventLine.format_event_line(
             %{kind: :read, topic: "ticket.99.branch.push", identifier: "830"},
             "830",
             nil
           ) == "📄 830 ingested 99: pushed"
  end

  test "entry with no ids resolves subject to question mark" do
    assert EventLine.format_event_line(%{kind: :receive, topic: "branch.push"}, nil, nil) ==
             "📬 ? received"
  end
end
