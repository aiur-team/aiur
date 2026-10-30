defmodule AiurWeb.ConversationLinkTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AiurWeb.Conversation.Components

  # The destination status remains reachable after legacy link emitters retire.
  test "unrecorded conversation offers an empty hint without hiding not-found or failures" do
    age = %{observed_at: nil, age_ms: nil, freshness: :unknown, text: "age unknown"}
    html = render_component(&Components.status/1, state: :not_found, age: age)
    assert html =~ "No messages yet"
    assert html =~ "Conversation not found"
    assert html =~ ~s(data-state="not_found")
    unavailable = render_component(&Components.status/1, state: :unavailable, age: age)
    refute unavailable =~ "No messages yet"
    assert unavailable =~ "Conversation unavailable"
  end
end
