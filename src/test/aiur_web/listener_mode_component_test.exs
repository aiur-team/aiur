defmodule AiurWeb.ListenerModeComponentTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AiurWeb.OperatorControlCenter.ListenerMode

  defp view(overrides \\ %{}) do
    now = DateTime.utc_now()
    Map.merge(%{requested: :sync, effective: :sync, effective_reason: nil, version: 0, routing: :listener, observed_at: now, unread_count: 0, oldest_unread_at: nil}, overrides)
  end

  defp render_mode(listener, opts \\ []) do
    render_component(&ListenerMode.listener_mode/1, Keyword.merge([listener: listener, now: DateTime.utc_now(), writable: true], opts))
  end

  test "unavailable and loading never invent a sync mode" do
    for state <- [:unavailable, :loading] do
      html = render_mode(state)
      assert html =~ if(state == :loading, do: "Loading listener mode", else: "Listener mode unavailable")
      refute html =~ "data-requested-mode"
      refute html =~ "Sync"
    end
  end

  test "default mode and read-only badge reflect the supplied values" do
    html = render_mode(view())
    assert html =~ ~s(data-requested-mode="sync")
    assert html =~ "Sync · next turn"
    assert html =~ ~s(name="expected_version" value="0")
    refute render_mode(view(), badge: true) =~ "<select"
    read_only = render_mode(view(), writable: false)
    assert read_only =~ "Read-only dashboard"
    assert read_only =~ "disabled"
  end

  test "legacy routing hides the selector" do
    html = render_mode(view(%{routing: :legacy}))
    assert html =~ "Legacy routing"
    refute html =~ "<select"
  end

  test "fallback, not running, paused and emulated interruption remain distinct" do
    for {reason, text} <- [{:not_running, "Agent not running"}, {:pull_tool_unavailable, "On-demand reading unavailable"}, {:emulated_interrupt, "Interrupts current turn"}] do
      html = render_mode(view(%{requested: :async, effective: :sync, effective_reason: reason, status: :paused}))
      assert html =~ ~s(data-effective-mode="sync")
      assert html =~ ~s(data-requested-mode="async")
      assert html =~ text
      assert html =~ "Agent paused"
    end
  end

  test "unread count renders the actual oldest age and observed stale age" do
    now = DateTime.utc_now()
    listener = view(%{requested: :async, effective: :async, unread_count: 2, oldest_unread_at: DateTime.add(now, -120), observed_at: DateTime.add(now, -45), freshness: :stale})
    html = render_mode(listener, now: now)
    assert html =~ ~s(data-unread-count="2")
    assert html =~ "oldest 120s ago"
    assert html =~ "Stale · 45s ago"
    assert html =~ "disabled"
    assert render_mode(Map.put(listener, :oldest_unread_at, nil), now: now) =~ "age unavailable"
  end

  test "pending conflict error and async exit notice are explicit" do
    assert render_mode(view(), feedback: %{state: :pending}) =~ "waiting for confirmation"
    conflict = render_mode(view(), feedback: %{state: :conflict, choice: :async})
    assert conflict =~ "Current winner: Sync"
    assert conflict =~ "Your choice: Async"
    assert render_mode(view(), feedback: %{state: :error}) =~ "could not be confirmed"
    assert render_mode(view(), feedback: %{left_async: true}) =~ "remain on demand"
  end

  test "receipts name every state without implying consumption" do
    for {state, text} <- [
          accepted: "Accepted",
          waiting_turn_end: "Waiting for turn end",
          held_async: "Held for the agent to read",
          harness_queued: "Handed to the agent",
          in_context: "In context",
          read: "Read",
          failed: "Failed",
          unknown: "Outcome unknown"
        ] do
      html = render_component(&ListenerMode.receipt/1, receipt: %{request_id: 7, receipt: state})
      assert html =~ ~s(data-receipt="#{state}")
      assert html =~ text
    end
  end
end
