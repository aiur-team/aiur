defmodule Aiur.BuildOrder.GraphProjection.Options do
  @moduledoc false

  alias Aiur.BuildOrder.{CatalogStore, GitHubGraph}
  alias Aiur.BuildOrder.GitHubGraph.Reconciliation
  alias Aiur.BuildOrder.GraphProjection.Policy
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Webhooks.DeliveryModeEvents

  @defaults [
    # No longer a refresh cadence: the catalog is event-sourced from the store
    # and rebuilt on change (#2313), so nothing polls on this. The value survives
    # as the failure-backoff base for the catalog scope, the window after which
    # the catalog snapshot is shown as ageing, and the floor the labelled-read
    # cadence rides on. The shipped value is a floor; production derives it from
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
    max_inflight: 4,
    # The catalog is event-sourced from `Aiur.GitHub.ResourceStore` (#2313), so
    # the old base for selected-root staleness and backoff — the catalog poll
    # cadence — no longer exists. Its replacement is delivery latency: the
    # longest a change can go unnoticed is `webhooks.silence_threshold_seconds`,
    # after which the delivery mode degrades and the projection reconciles from
    # GitHub. Derived from config; operators never set it directly.
    delivery_staleness_ms: 900_000,
    # How long a degraded repo waits between reconciliation attempts. A dropped
    # delivery re-converges on the next reconciliation, so this is the real
    # convergence bound while a tunnel is down; it defaults to the same silence
    # threshold the degradation itself is detected on.
    reconciliation_cooldown_ms: 900_000
  ]

  @maxima %{
    catalog_refresh_ms: 3_600_000,
    catalog_labels_refresh_ms: 3_600_000,
    refresh_timeout_ms: 120_000,
    max_selected_roots: 100,
    max_inflight: 16,
    delivery_staleness_ms: 3_600_000,
    reconciliation_cooldown_ms: 3_600_000
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
      catalog_reader: Keyword.get(opts, :catalog_reader, &CatalogStore.fetch/1),
      selected_reader: Keyword.get(opts, :selected_reader, &GitHubGraph.fetch_selected_root/2),
      reconciliation_fun: Keyword.get(opts, :reconciliation_fun, &Reconciliation.run/1),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      clock_ms: clock_ms(opts),
      configuration_subscriber: Keyword.get(opts, :configuration_subscriber, &Aiur.WorkflowStore.subscribe/1),
      resource_subscription: Keyword.get(opts, :resource_subscription, &default_resource_subscription/1),
      mode_events_subscriber: Keyword.get(opts, :mode_events_subscriber, &DeliveryModeEvents.subscribe/0),
      after_broadcast: Keyword.get(opts, :after_broadcast, fn _event -> :ok end),
      # The rare GraphQL reconciliation (boot, degraded delivery mode) that
      # re-converges the event-sourced store. `nil` when none is running;
      # `last_reconciliation_ms` gates how often a degraded repo re-converges.
      reconciliation: nil,
      last_reconciliation_ms: nil
    }
  end

  @spec policy_options(keyword()) :: map()
  def policy_options(opts) do
    catalog = positive(opts, :catalog_refresh_ms, @defaults[:catalog_refresh_ms], @maxima.catalog_refresh_ms)

    catalog_labels =
      positive(opts, :catalog_labels_refresh_ms, @defaults[:catalog_labels_refresh_ms], @maxima.catalog_labels_refresh_ms)

    timeout = positive(opts, :refresh_timeout_ms, @defaults[:refresh_timeout_ms], @maxima.refresh_timeout_ms)
    roots = positive(opts, :max_selected_roots, @defaults[:max_selected_roots], @maxima.max_selected_roots)

    %{
      catalog_refresh_ms: catalog,
      # The labelled read must never be more frequent than the catalog poll it
      # rides on: a shorter interval would make every poll buy the expensive
      # query, which is the regression #1766 exists to prevent. Clamping here
      # means no configuration can reinstate it.
      catalog_labels_refresh_ms: max(catalog_labels, catalog),
      refresh_timeout_ms: timeout,
      max_selected_roots: roots,
      max_inflight: positive(opts, :max_inflight, @defaults[:max_inflight], @maxima.max_inflight),
      # Re-based from `catalog_refresh_ms`: the catalog is event-sourced now, so
      # the real bound on how stale a watched root can be is delivery latency,
      # not a poll cadence (#2313). Both default to the webhook silence
      # threshold, which is the gap after which degradation triggers the
      # reconciliation that re-reads watched roots.
      delivery_staleness_ms: positive(opts, :delivery_staleness_ms, default_delivery_staleness_ms(), @maxima.delivery_staleness_ms),
      reconciliation_cooldown_ms:
        positive(
          opts,
          :reconciliation_cooldown_ms,
          @defaults[:reconciliation_cooldown_ms],
          @maxima.reconciliation_cooldown_ms
        )
    }
  end

  # `webhooks.silence_threshold_seconds` is the configured bound on how long a
  # change can go undelivered before the projection reconciles, so it is the
  # honest base for both selected-root staleness display and the failure
  # backoff. Config is not always readable at boot; the shipped default 900s
  # stands in for an unreadable value.
  defp default_delivery_staleness_ms do
    case Aiur.Config.settings() do
      %{webhooks: %{silence_threshold_seconds: seconds}} when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _other -> @defaults[:delivery_staleness_ms]
    end
  rescue
    _error -> @defaults[:delivery_staleness_ms]
  catch
    _kind, _reason -> @defaults[:delivery_staleness_ms]
  end

  # Subscribes the projection to the resource types the catalog is projected
  # from, so a delivery or mutation that changes one wakes a rebuild. Runs in
  # the projection's own process, so `ResourceStore.subscribe_type/1` delivers
  # `{:github_resource_changed, change}` to its mailbox.
  defp default_resource_subscription(_pid) do
    Enum.each([:issue, :issue_labels, :sub_issue, :issue_dependency], &ResourceStore.subscribe_type/1)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
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
