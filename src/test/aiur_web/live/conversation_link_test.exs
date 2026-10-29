defmodule AiurWeb.ConversationLinkTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures
  alias Aiur.Conversation.Ref
  alias AiurWeb.OperatorControlCenter.UnitsTableFixtures
  @endpoint AiurWeb.Endpoint

  test "drawer and units action use the row's durable identity in read-only mode" do
    identity = units_identity()
    {:ok, ref} = Ref.worker(identity)
    href = "/conversations/#{Ref.conversation_id(ref)}"
    handle = conversation_handle_value("a")
    name = Module.concat(__MODULE__, :Orchestrator)
    orchestrator = start_counting_orchestrator(name)
    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

    start_test_endpoint(
      orchestrator: name,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn ^handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn ^handle -> :ok end
    )

    {:ok, view, _html} = live(build_conn(), "/units")
    assert has_element?(view, ~s(.units-actions a[href="#{href}"]))
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()
    assert has_element?(view, ~s(#units-conversation-drawer a[href="#{href}"]), "Full conversation")
  end

  test "units link exists before the agent records messages" do
    row = UnitsTableFixtures.row()
    {:ok, ref} = Ref.worker(row.identity)
    html = UnitsTableFixtures.render_controls([row], %{}, false)
    assert html =~ ~s(href="/conversations/#{Ref.conversation_id(ref)}")
    assert html =~ "Full conversation for acme/aiur #1110"
  end

  test "unrecorded conversation offers an empty hint without hiding not-found or failures" do
    age = %{observed_at: nil, age_ms: nil, freshness: :unknown, text: "age unknown"}
    html = render_component(&AiurWeb.Conversation.Components.status/1, state: :not_found, age: age)
    assert html =~ "No messages yet"
    assert html =~ "Conversation not found"
    assert html =~ ~s(data-state="not_found")
    unavailable = render_component(&AiurWeb.Conversation.Components.status/1, state: :unavailable, age: age)
    refute unavailable =~ "No messages yet"
    assert unavailable =~ "Conversation unavailable"
  end

  # Future regression guard: the old table also omitted full-view links.
  test "future regression guard: unjoinable unit has no full conversation link" do
    row = UnitsTableFixtures.row()
    row = %{row | identity: %{row.identity | status: :unjoinable, reason: :missing_provider_id}}
    html = UnitsTableFixtures.render_controls([row], %{}, false)
    refute html =~ "/conversations/"
    refute html =~ "Full conversation"
  end
end
