defmodule AiurWeb.Conversation.EmbedTest do
  @moduledoc """
  The dashboard surface renders through the extracted `agent_conversation` package.

  These assertions are about the boundary, not about markup taste: the dashboard
  adapter must hand the package the same transcript row, host renderer and
  answering controls it used to render inline, and the package must produce the
  element the dashboard's own tests and browser specs navigate by.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Aiur.Conversation.Entry
  alias AiurWeb.Conversation.{Components, Minimap}

  # `History.mask_for/2` hands the view a plain map with `:redacted`, not a struct.
  defp entry(attrs) do
    %Entry{pos: 1, kind: "message", role: "agent", body: "hello"}
    |> Map.from_struct()
    |> Map.merge(attrs)
  end

  defp render_entry(attrs, opts \\ []) do
    render_component(&Components.entry/1, Keyword.merge([entry: entry(attrs)], opts))
  end

  test "an entry row keeps the dashboard's position attribute and host renderer" do
    rendered = render_entry(%{body: "**bold** <script>alert(1)</script>"})

    assert rendered =~ ~s(data-pos="1")
    assert rendered =~ "conversation-entry"
    assert rendered =~ "<strong>bold</strong>"
    refute rendered =~ "<script>"
    assert rendered =~ "&lt;script&gt;"
  end

  test "the dashboard keeps its reveal control for masked entries" do
    masked = render_entry(%{redacted: true}, can_reveal: true)

    assert masked =~ "masked"
    assert masked =~ ~s(phx-click="reveal_entry")
    assert masked =~ ~s(phx-value-pos="1")
    refute render_entry(%{redacted: true}) =~ "Show raw"
  end

  test "an entry carrying meta artifacts renders inline media without host credentials" do
    artifacts = [%{kind: "image", name: "screen.png", url: "https://cdn.example/screen.png"}]
    document = render_entry(%{meta: %{"artifacts" => artifacts}}) |> Floki.parse_fragment!()

    assert [figure] = Floki.find(document, "figure[data-media-kind=\"image\"]")
    assert Floki.attribute(figure, "img", "src") == ["https://cdn.example/screen.png"]
    assert Floki.attribute(document, "img", "alt") == ["Image: screen.png"]
  end

  test "an artifact with a refused URL falls back to text instead of loading it" do
    artifacts = [%{kind: "image", name: "x.png", url: "javascript:alert(1)"}]
    document = render_entry(%{meta: %{"artifacts" => artifacts}}) |> Floki.parse_fragment!()

    assert [] = Floki.find(document, "img")
    assert Floki.find(document, ".conversation-media[data-media-fallback]") != []
  end

  test "a session divider and truncation marker keep the dashboard's wording" do
    session = %Aiur.Conversation.Session{session_seq: 2, first_pos: 1, start_reason: "resume", started_at: "session-time"}
    rendered = render_entry(%{body_truncated: true}, sessions: [session])

    assert rendered =~ "Session 2"
    assert rendered =~ "Resumed after restart"
    assert rendered =~ ~s(datetime="session-time")
    assert rendered =~ "Middle of this output not stored"
  end

  test "the state header renders the dashboard label and freshness" do
    age = %{observed_at: DateTime.utc_now(), text: "3 seconds ago", freshness: "fresh"}
    rendered = render_component(&Components.status/1, state: :live, age: age)

    assert rendered =~ "Conversation"
    assert rendered =~ ~s(data-state="live")
    assert rendered =~ "3 seconds ago"
  end

  test "minimap rows come from anchors and keep transcript positions out" do
    anchors = [
      %{"pos" => 4, "kind" => "pr_merged", "label" => "PR #42 merged", "event" => %{"observed_at" => "2026-01-01T00:00:00Z"}},
      %{"pos" => "unusable", "kind" => "ci"},
      %{"kind" => "push"}
    ]

    assert [%{pos: 4, kind: "pr_merged", label: "PR #42 merged", at: "2026-01-01T00:00:00Z"}] = Minimap.rows(anchors)
    assert Minimap.rows(nil) == []
  end

  test "a minimap tick carries the jump event and its position without a transcript position" do
    rows = [%{pos: 4, kind: "pr_merged", label: "PR #42 merged", at: nil}]

    document =
      render_component(&Components.minimap/1, rows: rows, active_pos: 4, tick_attrs: %{"phx-click" => "jump_minimap"})
      |> Floki.parse_fragment!()

    assert [tick] = Floki.find(document, "button[data-tick-pos='4']")
    assert Floki.attribute(tick, "phx-click") == ["jump_minimap"]
    assert Floki.attribute(tick, "phx-value-pos") == ["4"]
    assert Floki.attribute(tick, "aria-current") == ["location"]
    assert Floki.attribute(tick, "aria-label") == ["PR #42 merged · position 4"]
    assert [] = Floki.find(document, "[data-pos]")
  end

  test "the minimap catalogue label is used when an anchor carries none" do
    assert [%{label: "PR merged"}] = Minimap.rows([%{"pos" => 9, "kind" => "pr_merged"}])
    assert [%{label: "Event"}] = Minimap.rows([%{"pos" => 9, "kind" => "unknown-kind"}])
  end
end
