defmodule Aiur.BuildOrder.GraphProjection.Options do
  @moduledoc false

  alias Aiur.BuildOrder.GitHubGraph
  alias Aiur.BuildOrder.GraphProjection.Policy

  @defaults [
    # The catalog's cadence *while a Build Order page is open*: `subscribe_catalog/1`
    # registers a viewer as a demander, and the cadence is armed only while at
    # least one demander is present (#2312). With no page open the catalog does
    # not run at all. The shipped value is a floor; production derives it from
    # the tracker's effective poll interval (see `Aiur.BuildOrder.Cadence`).
    catalog_refresh_ms: 60_000,
    # The catalog's per-member `labels` connection costs ~26 GraphQL points
    # against the 5,000-points/hour budget versus ~1 without it (#1766), so the
    # labelled read is bought on this slow cadence, not on every catalog poll.
    catalog_labels_refresh_ms: 600_000,
    # There is deliberately no `selected_refresh_ms` or `demand_refresh_ms`. A
    # selected root is not on a cadence: it is read when a writer or an explicit
    # `GraphProjection.refresh/2` asks for it, never because a page is open.
    refresh_timeout_ms: 30_000,
    max_selected_roots: 32,
    max_inflight: 4
  ]

  @maxima %{
    catalog_refresh_ms: 3_600_000,
    catalog_labels_refresh_ms: 3_600_000,
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
      # nil means "no labelled catalog read has landed under this authority", so
      # the first read after start or a configuration change buys the labels and
      # the page resolves its epic/wave counts promptly.
      catalog_labels_read_ms: nil,
      # Last labelled read that actually succeeded. Distinct from the gate above
      # because a failing labelled read must still back off, but must not make
      # the carried counts look freshly re-read.
      catalog_labels_ok_ms: nil,
      catalog_labels_failures: 0,
      catalog_labels_penalty_ms: 0,
      selected: %{},
      # Root key => the catalog change marker in force when that root's graph was
      # last read successfully. This is what makes a selected root writer-driven
      # instead of viewer-driven: the catalog reconciliation compares the marker
      # it just read against this one and asks for the root only when they
      # differ. Without it there would be no cadence *and* no trigger, which is
      # not "need-driven", it is "never read".
      selected_fingerprints: %{},
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
      authority_epoch: :unknown,
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
    # `catalog_refresh_ms` may be `0`: on-demand planning (#2309) means the
    # catalog has no timer, and `0` is the sentinel that tells `GraphProjection`
    # to refresh only on demand. Every other option stays strictly positive.
    catalog = catalog_refresh_ms(opts)

    catalog_labels =
      positive(opts, :catalog_labels_refresh_ms, @defaults[:catalog_labels_refresh_ms], @maxima.catalog_labels_refresh_ms)

    timeout = positive(opts, :refresh_timeout_ms, @defaults[:refresh_timeout_ms], @maxima.refresh_timeout_ms)
    roots = positive(opts, :max_selected_roots, @defaults[:max_selected_roots], @maxima.max_selected_roots)

    %{
      catalog_refresh_ms: catalog,
      # The labelled read must never be more frequent than the catalog poll it
      # rides on: a shorter interval would make every poll buy the expensive
      # query, which is the regression #1766 exists to prevent. Clamping here
      # means no configuration can reinstate it. An on-demand catalog (0) has no
      # cadence at all, so the labelled read's own interval is the floor.
      catalog_labels_refresh_ms: max(catalog_labels, catalog),
      refresh_timeout_ms: timeout,
      max_selected_roots: roots,
      max_inflight: positive(opts, :max_inflight, @defaults[:max_inflight], @maxima.max_inflight)
    }
  end

  # `0` (on-demand) is deliberate and preserved; only negatives and out-of-range
  # values fall back.
  defp catalog_refresh_ms(opts) do
    case Keyword.get(opts, :catalog_refresh_ms, @defaults[:catalog_refresh_ms]) do
      value when is_integer(value) and value >= 0 and value <= @maxima.catalog_refresh_ms -> value
      _ -> @defaults[:catalog_refresh_ms]
    end
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
