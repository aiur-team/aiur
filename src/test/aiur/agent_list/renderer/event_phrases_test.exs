defmodule Aiur.AgentList.Renderer.EventPhrasesTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.EventPhrases

  test "phrase_for_phase covers known phase steps and fallback" do
    assert EventPhrases.phrase_for_phase("brainstorm.start") == "started brainstorm"
    assert EventPhrases.phrase_for_phase("brainstorm.end") == "finished brainstorm"
    assert EventPhrases.phrase_for_phase("plan.start") == "started plan"
    assert EventPhrases.phrase_for_phase("plan.end") == "finished plan"
    assert EventPhrases.phrase_for_phase("work.start") == "started work"
    assert EventPhrases.phrase_for_phase("work.end") == "finished work"
    assert EventPhrases.phrase_for_phase("review.start") == "started review"
    assert EventPhrases.phrase_for_phase("review.end") == "finished review"
    assert EventPhrases.phrase_for_phase("other") == "phase other"
  end

  test "publish_event_phrase describes phases and progress" do
    assert EventPhrases.publish_event_phrase("agent.phase.work.start", %{"message" => "go"}) ==
             {"started work:", " \"go\""}

    assert EventPhrases.publish_event_phrase("agent.progress", %{percent: 40, label: "tests"}) ==
             {"Estimated progress: 40% done", " \"tests\""}
  end

  test "publish_event_phrase describes branch pushes, PRs, comments, and unknown topics" do
    assert EventPhrases.publish_event_phrase("branch.push", %{
             "commits" => [%{"message" => "first"}, %{"message" => "last"}]
           }) == {"pushed 2 commits, last:", " \"last\""}

    assert EventPhrases.publish_event_phrase("pr.opened", %{"pr" => %{"title" => "Open it"}}) ==
             {"opened a PR:", " \"Open it\""}

    assert EventPhrases.publish_event_phrase("issue.commented", %{
             "comment" => %{"body" => "Ship it"}
           }) == {"got an issue comment:", " \"Ship it\""}

    assert EventPhrases.publish_event_phrase("custom.topic", %{"summary" => "hello"}) ==
             {"custom.topic", " \"hello\""}
  end

  test "clip_summary and get_in_safe handle whitespace and missing payloads" do
    assert EventPhrases.clip_summary("a\n\n b\tc") == "a b c"
    assert EventPhrases.get_in_safe(nil, [:a]) == nil
    assert EventPhrases.get_in_safe(%{}, [:missing]) == nil
  end
end
