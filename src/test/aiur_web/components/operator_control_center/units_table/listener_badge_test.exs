defmodule AiurWeb.OperatorControlCenter.UnitsTable.ListenerBadgeTest do
  use ExUnit.Case, async: true

  import AiurWeb.OperatorControlCenter.UnitsTableFixtures

  test "ordinary, unavailable and legacy rows contain no listener badge" do
    for unit <- [row(), Map.put(row(), :listener, :unavailable), Map.put(row(), :listener, %{}), Map.put(row(), :listener, %{routing: :legacy, requested: :sync})] do
      html = render(view([unit]))
      refute html =~ "data-listener-badge"
      refute html =~ "listener-mode"
      refute html =~ "Listener mode unavailable"
      refute html =~ "Legacy routing"
    end
  end

  test "listener row mounts only the compact mode and count without a live region" do
    unit = Map.put(row(), :listener, %{routing: :listener, requested: :async, effective: :sync, effective_reason: :not_running, unread_count: 2})
    html = render(view([unit]))
    assert html =~ ~s(class="u-pill u-listener" data-listener-badge)
    assert html =~ ~s(data-requested-mode="async">Async · pings only</span>)
    assert html =~ ~s(data-unread-count="2")
    assert html =~ "Unread 2"
    refute html =~ ~s(role="status")
    refute html =~ "Agent not running"
    refute html =~ "Effective:"
    refute html =~ "Observed"
    refute html =~ "oldest"
  end

  test "listener row exposes unknown mode and count" do
    html = render(view([Map.put(row(), :listener, %{routing: :listener})]))
    assert html =~ ~s(data-requested-mode="unavailable">Unavailable</span>)
    assert html =~ ~s(data-unread-count="unknown")
    assert html =~ "Unread ?"
    refute html =~ "Unread 0"
  end
end
