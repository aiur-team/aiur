Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.Conversation.RevealTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias AiurWeb.Endpoint
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport

  setup context, do: TestSupport.setup(context)

  defp open(ref, ip, peer_ip \\ nil) do
    conn = %{build_conn() | remote_ip: ip}
    conn = Plug.Conn.put_private(conn, :live_view_connect_info, %{peer_data: %{address: peer_ip || ip}})
    live(conn, "/conversations/" <> Ref.conversation_id(ref))
  end

  test "loopback reveal re-reads exactly one masked entry and enforces writable mode", %{ref: ref} do
    Phoenix.Config.put(Endpoint, :dashboard_writable, true)
    secret = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ref, source(), [%{event(1) | body: secret}, %{event(2) | body: secret}])
    assert :ok = flush(ref)
    {:ok, view, html} = open(ref, {127, 0, 0, 1})
    refute html =~ secret
    assert has_element?(view, "#entry-1 button", "Show raw")
    render_click(element(view, "#entry-1 button", "Show raw"))
    assert has_element?(view, "#entry-1", secret)
    refute has_element?(view, "#entry-2", secret)

    for pos <- [nil, 2, "0", "-1", "9999", "2junk"] do
      render_click(view, "reveal_entry", %{"pos" => pos})
      refute has_element?(view, "#entry-2", secret)
    end

    Phoenix.Config.put(Endpoint, :dashboard_writable, false)
    render_click(view, "reveal_entry", %{"pos" => "2"})
    refute has_element?(view, "#entry-2", secret)
  end

  test "nonloopback Basic Auth and read-only sessions reject forged reveal events", %{ref: ref} do
    secret = "ghp_" <> String.duplicate("a", 36)
    Ingest.append(ref, source(), [%{event(1) | body: secret}])
    assert :ok = flush(ref)

    for {ip, peer_ip, writable} <- [
          {{192, 0, 2, 1}, {192, 0, 2, 1}, true},
          {{127, 0, 0, 1}, {127, 0, 0, 1}, false},
          {{127, 0, 0, 1}, {192, 0, 2, 1}, true},
          {{192, 0, 2, 1}, {127, 0, 0, 1}, true}
        ] do
      Phoenix.Config.put(Endpoint, :dashboard_writable, writable)
      {:ok, view, html} = open(ref, ip, peer_ip)
      refute html =~ "Show raw"
      refute render_click(view, "reveal_entry", %{"pos" => "1"}) =~ secret
    end
  end
end
