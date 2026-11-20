defmodule AiurWeb.OperatorControlCenter.DecisionDetailTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures
  alias AiurWeb.OperatorControlCenter.DecisionDetail

  test "detail shows the request position in read-only mode" do
    html = detail(%{href: "/conversations/conv_request?pos=42", precision: "exact"})
    assert Floki.parse_fragment!(html) |> Floki.find("a[href='/conversations/conv_request?pos=42']") |> Floki.text() == "Open in conversation"
    refute html =~ "Conversation position unknown"
    refute html =~ "(approximate)"
  end

  test "detail without an anchor reports unknown and offers no conversation link" do
    html = detail(nil)
    assert html =~ "Conversation position unknown"
    assert Floki.parse_fragment!(html) |> Floki.find("a[href^='/conversations/']") == []
  end

  test "observed precision labels the request position as approximate" do
    html = detail(%{href: "/conversations/conv_request?pos=7", precision: "observed"})
    assert Floki.parse_fragment!(html) |> Floki.find("a[href='/conversations/conv_request?pos=7']") |> Floki.text() == "Open in conversation (approximate)"
  end

  defp detail(link), do: render_component(&DecisionDetail.decision_detail/1, decision: inbox_decision("request"), writable: false, conversation_link: link)
end
