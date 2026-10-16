defmodule AiurWeb.Experiments.SourceTest do
  use ExUnit.Case, async: false

  alias AiurWeb.Experiments.Source

  defmodule Facade do
    def metric_catalog, do: Process.get(:experiments_catalog, %{metrics: %{}})
    def list, do: Process.get(:experiments_list, {:ok, []})
    def fetch(id), do: Process.get({:experiments_detail, id}, {:error, :not_found})
    def status, do: Process.get(:experiments_status, %{available?: true, store: :ok, capture: :off})

    def subscribe do
      send(self(), :subscribed_to_experiments)
      :ok
    end
  end

  setup do
    previous = Application.get_env(:aiur, :experiments_facade)
    Application.put_env(:aiur, :experiments_facade, Facade)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_facade, previous), else: Application.delete_env(:aiur, :experiments_facade)
    end)

    :ok
  end

  test "index hydrates cohort design from fetch and orders the facade summaries" do
    Process.put(:experiments_list, {:ok, [summary("old", "concluded"), summary("active", "active")]})

    for id <- ["old", "active"] do
      Process.put({:experiments_detail, id}, {:ok, %{spec: %{"design" => %{"kind" => "ab", "cohorts" => [%{}, %{}, %{}]}}}})
    end

    assert {:ok, [active, old]} = Source.index()
    assert active.id == "active"
    assert old.id == "old"
    assert active.kind_label == "A/B/C"
    assert active.evidence_state == :pending
    assert {:ok, %{id: "active", metrics: [], frozen_baseline: :unknown}} = Source.detail("active")
  end

  test "detail uses custom pack labels and units from the facade catalog" do
    Process.put(:experiments_catalog, %{metrics: %{"custom/checkout_latency_ms" => %{label: "Checkout latency", unit: "ms", default_direction: "decrease"}}})
    Process.put({:experiments_detail, "checkout"}, {:ok, %{spec: %{"id" => "checkout", "metrics" => [%{"ref" => "custom/checkout_latency_ms"}]}}})
    assert {:ok, model} = Source.detail("checkout")
    assert [%{"label" => "Checkout latency", "unit" => "ms", "direction" => "decrease"}] = model.metric_specs
  end

  test "empty index stays empty" do
    assert Source.index() == {:ok, []}
  end

  test "read failures map to a path-free store error and unknown ids stay distinct" do
    Process.put(:experiments_list, {:error, :enoent})
    assert Source.index() == {:error, :store_unreadable}
    assert Source.detail("missing") == {:error, :not_found}
    Process.put({:experiments_detail, "bad"}, {:error, {:unreadable, "/private/store"}})
    assert Source.detail("bad") == {:error, :store_unreadable}

    Process.put(:experiments_list, {:ok, [summary("bad", "active")]})
    assert Source.index() == {:error, :store_unreadable}
  end

  test "status retains capture state and removes internal store errors" do
    assert Source.status() == %{available?: true, store: :ok, capture: :off}
    Process.put(:experiments_status, %{available?: false, store: {:error, :disabled}, capture: :off})
    assert Source.status() == %{available?: false, store: {:error, :disabled}, capture: :off}
    Process.put(:experiments_status, %{available?: false, store: {:error, {:unreadable, "/private/store"}}, capture: :on})
    assert Source.status() == %{available?: false, store: {:error, :store_unreadable}, capture: :on}
  end

  test "subscription uses the facade" do
    assert Source.subscribe() == :ok
    assert_receive :subscribed_to_experiments, 100
  end

  defp summary(id, status), do: %{id: id, title: id, status: status, created_at: "2026-10-09T00:00:00Z", kind: "ab"}
end
