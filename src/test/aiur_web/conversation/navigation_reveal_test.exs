Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.Conversation.NavigationRevealTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias AiurWeb.Endpoint
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport

  setup context do
    ctx = TestSupport.setup(context)
    Phoenix.Config.put(Endpoint, :dashboard_writable, true)
    secret = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ctx.ref, source(), [%{event(1) | body: secret}, %{event(2) | body: secret}])
    :ok = flush(ctx.ref)
    conn = %{build_conn() | remote_ip: {127, 0, 0, 1}}
    conn = Plug.Conn.put_private(conn, :live_view_connect_info, %{peer_data: %{address: {127, 0, 0, 1}}})
    {:ok, view, _} = live(conn, "/conversations/" <> Ref.conversation_id(ctx.ref))
    render_click(element(view, "#entry-1 button", "Show raw"))
    assert has_element?(view, "#entry-1", secret)
    Map.merge(ctx, %{view: view, secret: secret})
  end

  test "revealed entry survives live anchor refresh while its marker renders", ctx do
    add_anchor(ctx)
    assert has_element?(ctx.view, "#entry-1", ctx.secret)
    assert has_element?(ctx.view, "#entry-1 #marker-1-pr_merged", "PR merged")
    add_anchor(ctx, 2)
    assert has_element?(ctx.view, "#entry-2 #marker-2-pr_merged", "PR merged")
    refute has_element?(ctx.view, "#entry-2", ctx.secret)
  end

  test "around reload preserves only chosen reveals and identifies the current location", ctx do
    render_patch(ctx.view, "/conversations/#{Ref.conversation_id(ctx.ref)}?pos=1")
    assert has_element?(ctx.view, "#entry-1", ctx.secret)
    refute has_element?(ctx.view, "#entry-2", ctx.secret)
    assert has_element?(ctx.view, "#entry-1[aria-current=location]")
    assert has_element?(ctx.view, ".event-filters[role=group][aria-label='Event kinds']")
    add_anchor(ctx)
    assert has_element?(ctx.view, "#marker-1-pr_merged[aria-current=location]")
  end

  test "refresh rechecks reveal permission before restoring the viewer's selection", ctx do
    Phoenix.Config.put(Endpoint, :dashboard_writable, false)
    add_anchor(ctx)
    refute has_element?(ctx.view, "#entry-1", ctx.secret)
    assert has_element?(ctx.view, "#marker-1-pr_merged")
    Phoenix.Config.put(Endpoint, :dashboard_writable, true)
    add_anchor(ctx)
    assert has_element?(ctx.view, "#entry-1", ctx.secret)
    refute has_element?(ctx.view, "#entry-2", ctx.secret)
  end

  defp add_anchor(ctx, pos \\ 1) do
    anchor = %{
      "event" => %{"event_id" => pos, "observed_at" => DateTime.to_iso8601(ctx.now)},
      "conversation_id" => Ref.conversation_id(ctx.ref),
      "kind" => "pr_merged",
      "pos" => pos,
      "placement" => "after",
      "precision" => "observed",
      "label" => "PR merged"
    }

    send(ctx.view.pid, {:anchor_added, Ref.conversation_id(ctx.ref), anchor})
    render(ctx.view)
  end
end
