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

  test "unknown-kind entries render no line" do
    assert EventLine.format_event_line(%{kind: :other, topic: "ticket.1.branch.push"}, "1", nil) ==
             "· 1 "
  end

  test "non-map entries render no line" do
    assert EventLine.format_event_line(:not_a_map, "1", nil) == nil
    assert EventLine.format_event_line(%{topic: "x"}, "1", nil) == nil
  end

  test "event_glyph maps each kind and falls back for unknowns" do
    assert EventLine.event_glyph(:publish) == "💬"
    assert EventLine.event_glyph(:receive) == "📬"
    assert EventLine.event_glyph(:read) == "📄"
    assert EventLine.event_glyph(:anything_else) == "·"
  end

  test "event_source_ticket_id extracts the ticket id or nil" do
    assert EventLine.event_source_ticket_id("ticket.140.branch.push") == "140"
    assert EventLine.event_source_ticket_id("branch.push") == nil
    assert EventLine.event_source_ticket_id(nil) == nil
    assert EventLine.event_source_ticket_id(%{}) == nil
  end

  test "ticker_self_echo? suppresses only self non-comment receives" do
    assert EventLine.ticker_self_echo?(
             :receive,
             "ticket.140.branch.push",
             %{identifier: "140"}
           )

    refute EventLine.ticker_self_echo?(
             :receive,
             "ticket.140.issue.commented",
             %{identifier: "140"}
           )

    refute EventLine.ticker_self_echo?(
             :receive,
             "ticket.99.branch.push",
             %{identifier: "140"}
           )

    refute EventLine.ticker_self_echo?(:publish, "ticket.140.branch.push", %{identifier: "140"})
  end

  test "comment_topic? recognizes comment suffixes" do
    assert EventLine.comment_topic?("issue.commented")
    assert EventLine.comment_topic?("pr.review_comment")
    refute EventLine.comment_topic?("branch.push")
  end

  test "event_subject_id resolves the subject per kind and available ids" do
    assert EventLine.event_subject_id(:publish, %{}, "99", "rid") == "99"
    assert EventLine.event_subject_id(:receive, %{identifier: "140"}, "99", "rid") == "140"
    assert EventLine.event_subject_id(:read, %{identifier: "140"}, "99", "rid") == "140"
    assert EventLine.event_subject_id(:read, %{}, "99", "rid") == "99"
    assert EventLine.event_subject_id(:receive, %{}, nil, "rid") == "rid"
    assert EventLine.event_subject_id(:receive, %{}, nil, nil) == "?"
  end

  test "topic_suffix strips the ticket prefix or returns the topic verbatim" do
    assert EventLine.topic_suffix("ticket.140.agent.phase.work.start") == "agent.phase.work.start"
    assert EventLine.topic_suffix("ticket.140") == "140"
    assert EventLine.topic_suffix("branch.push") == "branch.push"
    assert EventLine.topic_suffix(nil) == ""
  end

  test "describe_event renders self comment receives" do
    body = %{"comment" => %{"body" => "hi there"}}

    assert EventLine.describe_event(:receive, "140", "140", "issue.commented", body) ==
             {"new Issue comment:", " \"hi there\""}

    assert EventLine.describe_event(:receive, "140", "140", "pr.review_comment", body) ==
             {"new PR comment:", " \"hi there\""}
  end

  test "describe_event renders cross-ticket and fallback receives" do
    body = %{"commits" => [%{"message" => "init"}]}

    assert EventLine.describe_event(:receive, "830", "99", "branch.push", body) ==
             {"← 99: pushed", " \"init\""}

    assert EventLine.describe_event(:receive, "830", nil, "branch.push", nil) == {"received", ""}
  end

  test "describe_event renders read ingestion lines" do
    assert EventLine.describe_event(:read, "830", "99", "branch.push", nil) ==
             {"ingested 99: pushed", ""}

    assert EventLine.describe_event(:read, "830", "830", "branch.push", nil) ==
             {"ingested: pushed", ""}
  end

  test "describe_event renders publishes and ignores unknown kinds" do
    assert EventLine.describe_event(:publish, "830", "830", "issue.commented", %{}) ==
             {"got an issue comment:", ""}

    assert EventLine.describe_event(:other, "830", "830", "branch.push", nil) == {"", ""}
  end

  test "cross_receive_verb maps every known suffix" do
    assert EventLine.cross_receive_verb("branch.push") == "pushed"
    assert EventLine.cross_receive_verb("pr.opened") == "opened a PR"
    assert EventLine.cross_receive_verb("pr.merged") == "merged a PR"
    assert EventLine.cross_receive_verb("pr.review_comment") == "PR review comment"
    assert EventLine.cross_receive_verb("issue.commented") == "commented"
    assert EventLine.cross_receive_verb("agent.unblocked") == "unblocked"
    assert EventLine.cross_receive_verb("agent.blocked") == "blocked"
    assert EventLine.cross_receive_verb("agent.phase.work.start") == "started work"
    assert EventLine.cross_receive_verb("agent.progress") == "progress"
    assert EventLine.cross_receive_verb("agent.custom") == "custom"
    assert EventLine.cross_receive_verb("something.else") == "something.else"
  end

  test "cross_receive_summary summarizes each topic family" do
    assert EventLine.cross_receive_summary("branch.push", %{"commits" => [%{"message" => "init"}]}) ==
             " \"init\""

    assert EventLine.cross_receive_summary("branch.push", nil) == ""

    assert EventLine.cross_receive_summary("pr.opened", %{"pr" => %{"title" => "Fix bug"}}) ==
             " \"Fix bug\""

    assert EventLine.cross_receive_summary("pr.merged", %{}) == ""

    assert EventLine.cross_receive_summary("issue.commented", %{"comment" => %{"body" => "yo"}}) ==
             " \"yo\""

    assert EventLine.cross_receive_summary("agent.blocked", %{"message" => "waiting"}) ==
             " \"waiting\""
  end
end
