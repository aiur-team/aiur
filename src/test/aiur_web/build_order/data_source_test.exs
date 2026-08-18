defmodule AiurWeb.BuildOrder.DataSourceTest do
  use ExUnit.Case, async: true

  alias AiurWeb.BuildOrder.DataSource

  defmodule ProjectionSpy do
    def catalog, do: notify(:catalog, :catalog_snapshot)
    def subscribe_catalog, do: notify(:subscribe_catalog, :ok)
    def catalog_topic(repository), do: notify({:catalog_topic, repository}, "catalog-topic")
    def subscribe_selected(identity), do: notify({:subscribe_selected, identity}, :ok)
    def selected(identity), do: notify({:selected, identity}, {:ok, :selected_snapshot})
    def demand(identity), do: notify({:demand, identity}, {:ok, :demand_snapshot})
    def release(identity), do: notify({:release, identity}, :ok)
    def selected_topic(identity), do: notify({:selected_topic, identity}, "selected-topic")

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule ActivitySpy do
    def subscribe, do: notify(:subscribe_activity, :ok)
    def snapshots, do: notify(:load_activity, :activity_snapshots)

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule AgentPubSubSpy do
    def subscribe_running, do: notify(:subscribe_running, :ok)

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule StatusSpy do
    def snapshot_api, do: notify(:load_execution, :execution_snapshot)

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule AdHocSpy do
    def subscribe, do: notify(:subscribe_adhoc, :ok)
    def snapshot, do: notify(:load_adhoc, :adhoc_snapshot)

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule DetailSpy do
    def subscribe(identity), do: notify({:subscribe_detail, identity}, :ok)
    def request(identity), do: notify({:request_detail, identity}, {:ok, :detail_state})
    def topic(identity), do: notify({:detail_topic, identity}, "detail-topic")

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  defmodule HistorySpy do
    def subscribe(identity), do: notify({:subscribe_history, identity}, :ok)
    def request(identity), do: notify({:request_history, identity}, {:ok, :history_snapshot})
    def topic(identity), do: notify({:history_topic, identity}, "history-topic")

    defp notify(message, result) do
      send(self(), message)
      result
    end
  end

  test "delegates projection reads, subscriptions, demand, and release without a provider surface" do
    opts = [graph_projection: ProjectionSpy]

    assert DataSource.catalog(opts) == :catalog_snapshot
    assert DataSource.subscribe_catalog(opts) == :ok
    assert DataSource.subscribe_selected(:root, opts) == :ok
    assert DataSource.selected(:root, opts) == {:ok, :selected_snapshot}
    assert DataSource.demand(:root, opts) == {:ok, :demand_snapshot}
    assert DataSource.release(:root, opts) == :ok

    assert_received :catalog
    assert_received :subscribe_catalog
    assert_received {:subscribe_selected, :root}
    assert_received {:selected, :root}
    assert_received {:demand, :root}
    assert_received {:release, :root}

    forbidden = [:refresh_catalog, :github, :provider, :mutate, :update, :create, :delete]
    exports = DataSource.__info__(:functions)

    refute Enum.any?(exports, fn {name, _arity} -> name in forbidden end)
  end

  test "loads activity and execution from their complete cached snapshots" do
    opts = [ticket_activity: ActivitySpy, agent_pubsub: AgentPubSubSpy, status_report: StatusSpy, adhoc_source: AdHocSpy]

    assert DataSource.subscribe_sources(opts) == :ok

    assert DataSource.load_runtime_sources(opts) == %{
             activity: :activity_snapshots,
             execution: :execution_snapshot
           }

    assert DataSource.load_sources(opts) == %{
             activity: :activity_snapshots,
             execution: :execution_snapshot,
             adhoc: :adhoc_snapshot
           }

    assert_received :subscribe_activity
    assert_received :subscribe_running
    assert_received :subscribe_adhoc
    assert_received :load_activity
    assert_received :load_execution
    assert_received :load_adhoc
  end

  test "unsubscribes the prior repository catalog topic without touching provider state" do
    unsubscribe = fn topic ->
      send(self(), {:unsubscribe, topic})
      :ok
    end

    assert DataSource.unsubscribe_catalog({"owner", "repo"}, graph_projection: ProjectionSpy, unsubscribe: unsubscribe) == :ok

    assert_received {:catalog_topic, {"owner", "repo"}}
    assert_received {:unsubscribe, "catalog-topic"}
  end

  test "loads and unsubscribes context only through the two bounded caches" do
    unsubscribe = fn topic ->
      send(self(), {:unsubscribe, topic})
      :ok
    end

    opts = [ticket_detail_coordinator: DetailSpy, ticket_history_provider: HistorySpy, unsubscribe: unsubscribe]

    assert DataSource.subscribe_context(:ticket, opts) == :ok

    assert DataSource.load_context(:ticket, opts) == %{
             detail: {:ok, :detail_state},
             history: {:ok, :history_snapshot}
           }

    assert DataSource.unsubscribe_context(:ticket, opts) == :ok

    assert_received {:subscribe_detail, :ticket}
    assert_received {:subscribe_history, :ticket}
    assert_received {:request_detail, :ticket}
    assert_received {:request_history, :ticket}
    assert_received {:detail_topic, :ticket}
    assert_received {:history_topic, :ticket}
    assert_received {:unsubscribe, "detail-topic"}
    assert_received {:unsubscribe, "history-topic"}
  end

  test "unsubscribes a selected root without releasing its separately owned demand" do
    unsubscribe = fn topic ->
      send(self(), {:unsubscribe, topic})
      :ok
    end

    assert DataSource.unsubscribe_selected(:root, graph_projection: ProjectionSpy, unsubscribe: unsubscribe) == :ok

    assert_received {:selected_topic, :root}
    assert_received {:unsubscribe, "selected-topic"}
    refute_received {:release, :root}
  end
end
