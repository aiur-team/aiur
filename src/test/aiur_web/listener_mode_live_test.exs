defmodule AiurWeb.ListenerModeLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures
  @endpoint AiurWeb.Endpoint

  test "Units and drawer consume the projected listener facts and hide legacy selector" do
    identity = units_identity()
    handle = conversation_handle_value("l")
    name = Module.concat(__MODULE__, :SnapshotServer)
    orchestrator = start_counting_orchestrator(name)
    now = DateTime.utc_now()

    listener = %{
      requested: :async,
      effective: :sync,
      effective_reason: :pull_tool_unavailable,
      version: 3,
      routing: :legacy,
      observed_at: now,
      unread_count: 2,
      oldest_unread_at: DateTime.add(now, -120)
    }

    snapshot = units_conversation_snapshot(identity, handle)
    [running] = snapshot.running
    replace_counting_snapshot(orchestrator, %{snapshot | running: [Map.put(running, :listener, listener)]})

    start_test_endpoint(
      orchestrator: name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _ -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _ -> :ok end,
      live_conversation_unsubscribe_fun: fn _ -> :ok end
    )

    {:ok, view, html} = live(build_conn(), "/units")
    assert html =~ ~s(data-requested-mode="async")
    assert html =~ ~s(data-unread-count="2")
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()
    assert has_element?(view, "#units-conversation-drawer [data-effective-mode=sync]")
    refute has_element?(view, "#units-conversation-drawer select[name=mode]")
    html = render(view)
    assert html =~ "oldest 12"
    assert html =~ "On-demand reading unavailable"
  end
end
