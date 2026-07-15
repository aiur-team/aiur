defmodule Aiur.BuildOrder.GraphProjection.Options do
  @moduledoc false

  alias Aiur.BuildOrder.GitHubGraph
  alias Aiur.BuildOrder.GraphProjection.Policy

  @defaults [
    catalog_refresh_ms: 60_000,
    selected_refresh_ms: 15_000,
    demand_refresh_ms: 5_000,
    refresh_timeout_ms: 30_000,
    max_selected_roots: 32,
    max_inflight: 4
  ]

  @maxima %{
    catalog_refresh_ms: 3_600_000,
    selected_refresh_ms: 300_000,
    demand_refresh_ms: 300_000,
    refresh_timeout_ms: 120_000,
    max_selected_roots: 100,
    max_inflight: 16
  }

  @spec new(keyword()) :: map()
  def new(opts) do
    opts = runtime_options(opts)
    policy = policy_options(opts)
    now_ms = clock_ms(opts).()

    %{
      catalog: Policy.unavailable_entry(:catalog, now_ms),
      selected: %{},
      inflight_by_ref: %{},
      pending: MapSet.new(),
      monitor_by_ref: %{},
      monitor_by_demand: %{},
      next_generation: 1,
      next_attempt: 1,
      next_timer_token: 1,
      active_repository: :unknown,
      active_configuration_generation: :unknown,
      authority_fingerprint: :unknown,
      authority_generation: 0,
      policy: policy,
      configured_repo: Keyword.get(opts, :configured_repo),
      configuration_generation: Keyword.get(opts, :configuration_generation, 1),
      configuration_snapshot: Keyword.get(opts, :configuration_snapshot),
      authority_snapshot: Keyword.get(opts, :authority_snapshot),
      runtime_options: Keyword.get(opts, :runtime_options, &Aiur.Config.build_order_graph_projection_options/0),
      root_limit: positive(opts, :root_limit, 100, 100),
      page_budget: positive(opts, :page_budget, 4, 4),
      call_budget: positive(opts, :call_budget, 4, 4),
      catalog_reader: Keyword.get(opts, :catalog_reader, &GitHubGraph.fetch_catalog/1),
      selected_reader: Keyword.get(opts, :selected_reader, &GitHubGraph.fetch_selected_root/2),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      clock_ms: clock_ms(opts),
      configuration_subscriber: Keyword.get(opts, :configuration_subscriber, &Aiur.WorkflowStore.subscribe/1),
      after_broadcast: Keyword.get(opts, :after_broadcast, fn _event -> :ok end)
    }
  end

  @spec policy_options(keyword()) :: map()
  def policy_options(opts) do
    selected = positive(opts, :selected_refresh_ms, @defaults[:selected_refresh_ms], @maxima.selected_refresh_ms)
    demand = positive(opts, :demand_refresh_ms, @defaults[:demand_refresh_ms], @maxima.demand_refresh_ms)
    catalog = positive(opts, :catalog_refresh_ms, @defaults[:catalog_refresh_ms], @maxima.catalog_refresh_ms)
    timeout = positive(opts, :refresh_timeout_ms, @defaults[:refresh_timeout_ms], @maxima.refresh_timeout_ms)
    roots = positive(opts, :max_selected_roots, @defaults[:max_selected_roots], @maxima.max_selected_roots)

    %{
      catalog_refresh_ms: catalog,
      selected_refresh_ms: selected,
      demand_refresh_ms: if(demand <= selected, do: demand, else: @defaults[:demand_refresh_ms]),
      refresh_timeout_ms: timeout,
      max_selected_roots: roots,
      max_inflight: positive(opts, :max_inflight, @defaults[:max_inflight], @maxima.max_inflight)
    }
  end

  defp runtime_options(opts) do
    case Keyword.pop(opts, :runtime_config?, false) do
      {true, opts} -> Keyword.merge(Aiur.Config.build_order_graph_projection_options(), opts)
      {_runtime_config, opts} -> opts
    end
  end

  defp clock_ms(opts), do: Keyword.get(opts, :clock_ms, fn -> System.monotonic_time(:millisecond) end)

  defp positive(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum -> value
      _ -> default
    end
  end
end
