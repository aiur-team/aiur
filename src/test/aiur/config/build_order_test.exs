defmodule Aiur.Config.BuildOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphProjection.Options
  alias Aiur.Config
  alias Aiur.Config.Schema

  test "uses bounded projection and ticket-detail cache defaults" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_freshness_ms == 30_000
    assert settings.build_order.ticket_detail_max_entries == 32
    assert settings.build_order.ticket_detail_max_description_bytes == 16_384
    assert settings.build_order.ticket_history_limit == 50
    assert settings.build_order.ticket_history_max_identities == 100
    assert settings.build_order.ticket_history_stale_after_ms == 60_000
    assert settings.build_order.graph_catalog_refresh_ms == 60_000
    assert settings.build_order.graph_catalog_labels_refresh_ms == 600_000
    assert settings.build_order.graph_selected_refresh_ms == 15_000
    assert settings.build_order.graph_demand_refresh_ms == 5_000
    assert settings.build_order.graph_refresh_timeout_ms == 30_000
    assert settings.build_order.graph_max_selected_roots == 32
    assert settings.build_order.graph_max_inflight == 4
  end

  test "accepts explicit projection and ticket-detail cache bounds" do
    assert {:ok, settings} =
             Schema.parse(%{
               "build_order" => %{
                 "ticket_detail_freshness_ms" => 10_000,
                 "ticket_detail_max_entries" => 12,
                 "ticket_detail_max_description_bytes" => 4_096,
                 "ticket_history_limit" => 12,
                 "ticket_history_max_identities" => 24,
                 "ticket_history_stale_after_ms" => 120_000,
                 "graph_catalog_refresh_ms" => 120_000,
                 "graph_catalog_labels_refresh_ms" => 900_000,
                 "graph_selected_refresh_ms" => 30_000,
                 "graph_demand_refresh_ms" => 10_000,
                 "graph_refresh_timeout_ms" => 20_000,
                 "graph_max_selected_roots" => 12,
                 "graph_max_inflight" => 2
               }
             })

    assert settings.build_order.ticket_detail_freshness_ms == 10_000
    assert settings.build_order.ticket_detail_max_entries == 12
    assert settings.build_order.ticket_detail_max_description_bytes == 4_096
    assert settings.build_order.ticket_history_limit == 12
    assert settings.build_order.ticket_history_max_identities == 24
    assert settings.build_order.ticket_history_stale_after_ms == 120_000
    assert settings.build_order.graph_catalog_refresh_ms == 120_000
    assert settings.build_order.graph_catalog_labels_refresh_ms == 900_000
    assert settings.build_order.graph_selected_refresh_ms == 30_000

    # The setting is inert unless it reaches the projection's policy, so pin
    # both halves of the wiring: Config exports the key, and policy_options/1
    # maps it through rather than falling back to the default.
    assert Keyword.has_key?(Config.build_order_graph_projection_options(), :catalog_labels_refresh_ms)

    policy =
      Options.policy_options(
        catalog_refresh_ms: 120_000,
        catalog_labels_refresh_ms: 900_000
      )

    assert policy.catalog_labels_refresh_ms == 900_000

    # And no configuration can make the expensive read outrun the catalog poll.
    clamped =
      Options.policy_options(
        catalog_refresh_ms: 120_000,
        catalog_labels_refresh_ms: 1_000
      )

    assert clamped.catalog_labels_refresh_ms == 120_000
    assert settings.build_order.graph_demand_refresh_ms == 10_000
    assert settings.build_order.graph_refresh_timeout_ms == 20_000
    assert settings.build_order.graph_max_selected_roots == 12
    assert settings.build_order.graph_max_inflight == 2
  end

  test "rejects unbounded or nonpositive ticket-detail cache configuration" do
    for attrs <- [
          %{"ticket_detail_freshness_ms" => 300_001},
          %{"ticket_detail_max_entries" => 101},
          %{"ticket_detail_max_description_bytes" => 16_385},
          %{"ticket_history_limit" => 101},
          %{"ticket_history_max_identities" => 101},
          %{"ticket_history_stale_after_ms" => 300_001},
          %{"ticket_history_limit" => 0},
          %{"ticket_detail_freshness_ms" => 0}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end

  test "rejects invalid projection bounds and demand intervals beyond the selected interval" do
    for attrs <- [
          %{"graph_catalog_refresh_ms" => 3_600_001},
          %{"graph_catalog_labels_refresh_ms" => 3_600_001},
          # A labels cadence faster than the catalog poll would make every poll
          # buy the ~26-point query — the regression #1766 exists to prevent.
          %{"graph_catalog_refresh_ms" => 60_000, "graph_catalog_labels_refresh_ms" => 59_999},
          %{"graph_selected_refresh_ms" => 300_001},
          %{"graph_demand_refresh_ms" => 0},
          %{"graph_refresh_timeout_ms" => 120_001},
          %{"graph_max_selected_roots" => 101},
          %{"graph_max_inflight" => 17},
          %{"graph_selected_refresh_ms" => 4_999, "graph_demand_refresh_ms" => 5_000}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end
end
