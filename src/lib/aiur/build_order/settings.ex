defmodule Aiur.BuildOrder.Settings do
  @moduledoc "Runtime options for Build Order consumers."

  alias Aiur.BuildOrder.Cadence
  alias Aiur.Config

  @doc false
  @spec build_order_ticket_detail_coordinator_options() :: keyword()
  def build_order_ticket_detail_coordinator_options do
    build_order = Config.settings!().build_order

    # Deliberately the *base* interval, unlike the graph cadences below.
    # `TicketDetailCoordinator` reads these options once, in `init/1`, and never
    # re-derives them — so a value taken from the effective interval would be
    # frozen at whatever the cadence happened to be at boot and would never
    # narrow again. It is also not part of what #2118 was about: this is a
    # conditional REST staleness window, where an unchanged refresh is a free
    # `304`, not an unconditional GraphQL read.
    [
      freshness_ms:
        Cadence.resolve(
          :ticket_detail_freshness_ms,
          build_order.ticket_detail_freshness_ms,
          Config.poll_interval_seconds()
        ),
      max_entries: build_order.ticket_detail_max_entries,
      max_description_bytes: build_order.ticket_detail_max_description_bytes
    ]
  end

  @doc false
  @spec build_order_ticket_history_options() :: keyword()
  def build_order_ticket_history_options do
    build_order = Config.settings!().build_order

    [
      history_limit: build_order.ticket_history_limit,
      max_identities: build_order.ticket_history_max_identities,
      stale_after_ms: build_order.ticket_history_stale_after_ms
    ]
  end

  @doc false
  @spec build_order_graph_projection_options() :: keyword()
  def build_order_graph_projection_options do
    build_order = Config.settings!().build_order

    # Derived from the tracker's *effective* cycle unless the operator said
    # otherwise — the interval the dispatcher actually scheduled, idle and
    # webhook widening included. Build Order shows state the tracker produces,
    # so a cadence faster than the poll re-reads a graph that cannot have moved:
    # the old 15s and 5s constants did that once #2064 slowed the tracker, and
    # the base interval did it again whenever the fleet went idle (#2118).
    #
    # `GraphProjection` calls this on every reconcile, so it derives once and
    # reads both keys off the same map rather than deriving twice.
    derived = Cadence.effective()

    [
      catalog_refresh_ms: Cadence.prefer_configured(build_order.graph_catalog_refresh_ms, derived, :graph_catalog_refresh_ms),
      catalog_labels_refresh_ms:
        Cadence.prefer_configured(
          build_order.graph_catalog_labels_refresh_ms,
          derived,
          :graph_catalog_labels_refresh_ms
        ),
      refresh_timeout_ms: build_order.graph_refresh_timeout_ms,
      max_selected_roots: build_order.graph_max_selected_roots,
      max_inflight: build_order.graph_max_inflight
    ]
  end
end
