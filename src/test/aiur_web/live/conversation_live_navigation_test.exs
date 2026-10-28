Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationLiveNavigationTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  import Aiur.Conversation.TestSupport
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]

  setup context do
    ctx = TestSupport.setup(context)
    Ingest.append(ctx.ref, source(), Enum.map(1..120, &event/1))
    :ok = flush(ctx.ref)
    ctx
  end

  defp open(ctx, query \\ "") do
    live(build_conn(), "/conversations/" <> Ref.conversation_id(ctx.ref) <> query)
  end

  defp anchor(ctx, id, attrs \\ %{}) do
    Map.merge(
      %{
        "event" => %{"event_id" => id, "observed_at" => DateTime.to_iso8601(ctx.now)},
        "kind" => "pr_merged",
        "conversation_id" => Ref.conversation_id(ctx.ref),
        "pos" => 60,
        "placement" => "at",
        "precision" => "exact",
        "label" => "PR ##{id} merged"
      },
      attrs
    )
  end

  defp persist(ctx, anchors), do: File.write!(Path.join(ctx.dir, "anchors.jsonl"), Enum.map(anchors, &(Jason.encode!(&1) <> "\n")))

  test "pos loads a centered page and highlights the requested position", ctx do
    {:ok, view, html} = open(ctx, "?pos=60")
    assert has_element?(view, "#entry-60.conversation-highlight[data-jump-target=true]")
    assert positions(html) == Enum.to_list(35..84)
    render_patch(view, "/conversations/#{Ref.conversation_id(ctx.ref)}?pos=10")
    assert has_element?(view, "#entry-10.conversation-highlight")
  end

  test "observed events use ordered markers after the entry with honest precision", ctx do
    persist(ctx, [anchor(ctx, 2, %{"placement" => "after", "precision" => "observed"}), anchor(ctx, 1, %{"placement" => "after", "precision" => "observed"})])
    {:ok, view, html} = open(ctx, "?pos=60")
    refute has_element?(view, "#entry-60.conversation-highlight")
    assert has_element?(view, "#entry-60 > .conversation-entry + #marker-1-pr_merged.conversation-highlight", "approximate position")
    assert html |> Floki.parse_document!() |> Floki.find("#entry-60 .conversation-event-marker") |> Enum.map(&Floki.attribute(&1, "id")) == [["marker-1-pr_merged"], ["marker-2-pr_merged"]]
  end

  test "unanchored events have no jump and catalogue defaults control visibility", ctx do
    persist(ctx, [anchor(ctx, 1, %{"pos" => nil, "placement" => nil, "precision" => "unanchored"}), anchor(ctx, 2, %{"kind" => "ci"})])
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#event-1-pr_merged", "Not linked to a position")
    refute has_element?(view, "#event-1-pr_merged a, #event-1-pr_merged [phx-click]")
    refute has_element?(view, "#event-2-ci")
    render_click(element(view, "[data-filter-kind=ci]"))
    assert has_element?(view, "#event-2-ci a[href$='?pos=60']")
    render_hook(view, "event_filters", %{"kinds" => ["ci", "unknown"]})
    refute has_element?(view, "#event-1-pr_merged")
    assert has_element?(view, "#event-2-ci")
  end

  test "live stronger anchor replaces weaker item and marker in place", ctx do
    weak = anchor(ctx, 1, %{"placement" => "after", "precision" => "observed"})
    persist(ctx, [weak])
    {:ok, view, _} = open(ctx, "?pos=60")
    send(view.pid, {:anchor_added, Ref.conversation_id(ctx.ref), anchor(ctx, 1)})
    assert has_element?(view, "#event-1-pr_merged[data-precision=exact]")
    refute has_element?(view, "#marker-1-pr_merged")
    assert has_element?(view, "#entry-60.conversation-highlight")
    send(view.pid, {:anchor_added, Ref.conversation_id(ctx.ref), weak})
    assert has_element?(view, "#event-1-pr_merged[data-precision=exact]")
    refute has_element?(view, "#event-1-pr_merged small")
  end

  test "beyond head falls back to tail and retries once after appended entries", ctx do
    {:ok, view, html} = open(ctx, "?pos=121")
    assert html =~ "Position not found"
    assert positions(html) == Enum.to_list(71..120)
    Ingest.append(ctx.ref, source(), [event(121)])
    assert :ok = flush(ctx.ref)
    assert has_element?(view, "#entry-121.conversation-highlight")
    refute has_element?(view, "#conversation-position-notice")
    render_patch(view, "/conversations/#{Ref.conversation_id(ctx.ref)}?pos=125")
    Ingest.append(ctx.ref, source(), [event(122)])
    assert :ok = flush(ctx.ref)
    assert has_element?(view, "#conversation-position-notice", "Position not found")
    Ingest.append(ctx.ref, source(), Enum.map(123..125, &event/1))
    assert :ok = flush(ctx.ref)
    refute has_element?(view, "#entry-125.conversation-highlight")
  end

  test "invalid positions fall back to tail while unreadable positions stay unavailable", ctx do
    {:ok, view, html} = open(ctx, "?pos=invalid")
    assert html =~ "Position not found"
    assert positions(html) == Enum.to_list(71..120)
    File.write!(Aiur.Conversation.Store.segment_path(ctx.dir, 1), "broken\n")
    render_patch(view, "/conversations/#{Ref.conversation_id(ctx.ref)}?pos=60")
    assert has_element?(view, "#conversation-position-notice", "Position unavailable")
    assert has_element?(view, "[data-state=unavailable]")
  end

  test "Command chips link safely and resolved Commands say answered", ctx do
    persist(ctx, [anchor(ctx, 1, %{"kind" => "command_requested", "subject_ref" => %{"decision_id" => "decision-1"}}), anchor(ctx, 2, %{"kind" => "command_resolved"})])
    {:ok, view, _} = open(ctx)
    assert has_element?(view, "#event-1-command_requested a[href='/commands/decision-1']", "Open Command")
    assert has_element?(view, "#event-2-command_resolved .command-chip", "answered")
  end

  test "event stream is bounded and older events remain reachable", ctx do
    persist(ctx, Enum.map(1..1010, &anchor(ctx, &1)))
    {:ok, view, html} = open(ctx)
    assert event_count(html) == 1000
    refute has_element?(view, "#event-1-pr_merged")
    send(view.pid, {:anchor_added, Ref.conversation_id(ctx.ref), anchor(ctx, 1011)})
    assert has_element?(view, "#event-1011-pr_merged")
    refute has_element?(view, "#event-11-pr_merged")
    html = render_click(element(view, "#events-older"))
    assert event_count(html) == 1000
    assert has_element?(view, "#event-1-pr_merged")
  end

  defp event_count(html), do: html |> Floki.parse_document!() |> Floki.find("#event-list > li") |> length()
  defp positions(html), do: html |> Floki.parse_document!() |> Floki.find("[data-pos]") |> Enum.map(fn node -> node |> Floki.attribute("data-pos") |> hd() |> String.to_integer() end)
end
