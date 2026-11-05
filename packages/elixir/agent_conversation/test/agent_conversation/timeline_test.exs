defmodule AgentConversation.TimelineTest do
  use ExUnit.Case, async: true

  alias AgentConversation.Timeline

  defp entry(pos, attrs \\ %{}) do
    Map.merge(%{pos: pos, kind: "message", role: "agent", body: "entry #{pos}"}, attrs)
  end

  defp page(entries, head, extra \\ %{}) do
    Map.merge(%{entries: entries, head_pos: head, complete_from_start: false, sessions: []}, extra)
  end

  test "a tail page and older pages assemble one ordered transcript" do
    timeline =
      Timeline.new()
      |> Timeline.merge(page(Enum.map(100..149, &entry/1), 149))
      |> Timeline.merge(page(Enum.map(50..99, &entry/1), 149), :older)

    assert Timeline.positions(timeline) == Enum.to_list(50..149)
    assert timeline.oldest_pos == 50
    assert timeline.newest_pos == 149
    assert Timeline.older?(timeline)
    assert Timeline.older_cursor(timeline) == 50
    assert length(Timeline.visible(timeline)) == 100
  end

  test "overlapping pages and repeated positions never duplicate a row" do
    timeline = Timeline.new() |> Timeline.merge(page([entry(1), entry(2), entry(3)], 3))
    merged = Timeline.merge(timeline, page([entry(2), entry(3), entry(4)], 4), :newer)

    assert Timeline.positions(merged) == [1, 2, 3, 4]
    assert merged.duplicates == 2
  end

  test "live entries at or below the head are discarded, above it appended" do
    timeline = Timeline.new() |> Timeline.merge(page([entry(1), entry(2)], 2))

    live = Timeline.live(timeline, [entry(1, %{body: "replayed"}), entry(2, %{body: "replayed"}), entry(3)])

    assert Timeline.positions(live) == [1, 2, 3]
    assert live.discarded == 2
    assert Enum.find(Timeline.visible(live), &(&1.pos == 2)).body == "entry 2"
  end

  test "a reconnect reconciles the catch-up page and reports the discarded replays" do
    timeline = Timeline.new() |> Timeline.merge(page([entry(1), entry(2)], 2))
    catch_up = page([entry(1), entry(2), entry(3)], 3)

    {reconciled, discarded} = Timeline.reconcile(timeline, catch_up, [entry(2), entry(3), entry(4)])

    assert Timeline.positions(reconciled) == [1, 2, 3, 4]
    assert discarded == 2
    assert length(Timeline.visible(reconciled)) == 4
  end

  test "a duplicate entry id is recognised even at a new position" do
    timeline = Timeline.new() |> Timeline.merge(page([entry(1, %{id: "same"})], 1))
    live = Timeline.live(timeline, [entry(2, %{id: "same"})])

    assert Timeline.positions(live) == [1]
    assert live.duplicates == 1
  end

  test "the minimap caps itself and prefers host anchors" do
    entries = Enum.map(1..300, &entry/1)
    timeline = Timeline.merge(Timeline.new(), page(entries, 300))

    assert length(Timeline.minimap(timeline)) == 200
    assert Timeline.minimap(timeline) |> List.last() |> Map.get(:pos) == 300

    anchors = [%{pos: 12, kind: "pr_merged", label: "PR merged", at: "2026-01-01T00:00:00Z"}]
    assert [%{pos: 12, kind: "pr_merged", label: "PR merged"}] = Timeline.minimap(timeline, anchors: anchors)
  end

  test "an empty timeline is distinguishable from a loading one" do
    timeline = Timeline.new()

    assert Timeline.empty?(timeline)
    assert Timeline.visible(timeline) == []
    assert Timeline.older_cursor(timeline) == nil
    assert Timeline.newer_cursor(timeline) == nil
  end
end
