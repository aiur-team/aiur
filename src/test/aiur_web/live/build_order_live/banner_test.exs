defmodule AiurWeb.BuildOrderLive.BannerTest do
  use AiurWeb.BuildOrderLiveCase

  alias Aiur.DecisionPubSub

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Build Order" do
    {:ok, _view, html} = live_settled("/build-orders")

    assert html =~ "2 units awaiting commands"
    assert html =~ ~s(href="/commands")
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "keeps its scoped decision store when live endpoint config changes" do
    {:ok, view, html} = live_settled("/build-orders")
    assert html =~ "2 units awaiting commands"

    endpoint_config = Application.get_env(:aiur, Endpoint, [])
    isolated_store = AiurWeb.EndpointConfig.get(:decision_store)

    assert {:ok, %{counts: %{awaiting: 2}, health: :writable}} = GenServer.call(isolated_store, :retained_counts)

    competing_store = AwaitingCommands.start(awaiting: 0)

    on_exit(fn ->
      if Process.whereis(Endpoint), do: Endpoint.config_change([{Endpoint, endpoint_config}], [])
      if is_pid(competing_store) and Process.alive?(competing_store), do: GenServer.stop(competing_store)
    end)

    :ok =
      Endpoint.config_change(
        [{Endpoint, Keyword.put(endpoint_config, :decision_store, competing_store)}],
        []
      )

    :ok = AwaitingCommands.put_counts(isolated_store, awaiting: 3)

    :ok = DecisionPubSub.broadcast_changed("concurrent-test-probe", 1)

    refreshed_html = LiveViewAsync.render_after_refresh(view)
    assert refreshed_html =~ "3 units awaiting commands"
    refute refreshed_html =~ "2 units awaiting commands"
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner from Build Order when nothing is waiting" do
    {:ok, _view, html} = live_settled("/build-orders")

    refute html =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    {:ok, view, html} = live_settled("/build-orders")
    assert html =~ "2 units awaiting commands"

    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end
end
