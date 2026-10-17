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
  test "keeps its decision store when shared endpoint config changes" do
    {:ok, view, html} = live_settled("/build-orders")
    assert html =~ "2 units awaiting commands"

    isolated_store = AiurWeb.EndpointConfig.get(:decision_store)
    assert {:registered_name, store_name} = Process.info(isolated_store, :registered_name)
    assert Atom.to_string(store_name) =~ "AwaitingCommands.Stub"
    assert {:ok, %{counts: %{awaiting: 2}, health: :writable}} = GenServer.call(isolated_store, :retained_counts)

    competing_store = AwaitingCommands.start(awaiting: 0)
    on_exit(fn -> if Process.alive?(competing_store), do: GenServer.stop(competing_store) end)
    endpoint_config = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.put(endpoint_config, :decision_store, competing_store))

    :ok = DecisionPubSub.broadcast_changed("concurrent-test-probe", 1)

    assert render(view) =~ "2 units awaiting commands"
    assert AiurWeb.EndpointConfig.get(:decision_store) == isolated_store
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
