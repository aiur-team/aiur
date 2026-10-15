defmodule AiurWeb.BuildOrderLive.BannerTest do
  use AiurWeb.BuildOrderLiveCase

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Build Order" do
    {:ok, _view, html} = live(build_conn(), "/build-orders")

    assert html =~ "2 units awaiting commands"
    assert html =~ ~s(href="/commands")
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner from Build Order when nothing is waiting" do
    {:ok, _view, html} = live(build_conn(), "/build-orders")

    refute html =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    {:ok, view, html} = live(build_conn(), "/build-orders")
    assert html =~ "2 units awaiting commands"

    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end
end
