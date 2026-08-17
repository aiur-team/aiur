defmodule Aiur.Config.BuildOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphProjection.Options
  alias Aiur.Config
  alias Aiur.Config.Schema

  # The three surviving cadence keys deliberately have no fixed default any more.
  # They were constants chosen when the tracker polled every 5 seconds, and
  # asserting those constants here is what let them survive #2064 slowing the
  # tracker to 120 — the test encoded the bug. `nil` means "derive from the poll
  # interval", and the derivation itself is asserted in
  # `Aiur.BuildOrder.CadenceTest`.
  test "leaves the poll-derived cadences unset so they can be derived" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_freshness_ms == nil
    assert settings.build_order.graph_catalog_refresh_ms == nil
    assert settings.build_order.graph_catalog_labels_refresh_ms == nil
  end

  # The two settings that let viewing buy GitHub reads are gone from the schema.
  # A configuration that still carries them must keep loading — `cast/3` ignores
  # keys outside the permitted list — so an operator upgrading gets the new
  # behaviour rather than a daemon that will not boot.
  # Asserted as "loading them changes nothing", not as "the struct lacks the
  # field". `settings.build_order` is an Ecto struct with a closed field set, so
  # `refute Map.has_key?(struct, :anything)` is statically true and would pass
  # against a schema that had reinstated both keys under different names — or
  # against one that honoured them.
  test "a configuration still setting the deleted viewer cadences still loads" do
    assert {:ok, with_deleted} =
             Schema.parse(%{
               "build_order" => %{
                 "graph_selected_refresh_ms" => 15_000,
                 "graph_demand_refresh_ms" => 5_000
               }
             })

    assert {:ok, without} = Schema.parse(%{})

    assert with_deleted.build_order == without.build_order,
           "the deleted viewer cadences must be inert; honouring one would let viewing buy GitHub reads again"
  end

  test "uses bounded projection and ticket-detail defaults for everything else" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_max_entries == 32
    assert settings.build_order.ticket_detail_max_description_bytes == 16_384
    assert settings.build_order.ticket_history_limit == 50
    assert settings.build_order.ticket_history_max_identities == 100
    assert settings.build_order.ticket_history_stale_after_ms == 60_000
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

  test "rejects invalid projection bounds" do
    for attrs <- [
          %{"graph_catalog_refresh_ms" => 3_600_001},
          %{"graph_catalog_labels_refresh_ms" => 3_600_001},
          # A labels cadence faster than the catalog poll would make every poll
          # buy the ~26-point query — the regression #1766 exists to prevent.
          %{"graph_catalog_refresh_ms" => 60_000, "graph_catalog_labels_refresh_ms" => 59_999},
          %{"graph_refresh_timeout_ms" => 120_001},
          %{"graph_max_selected_roots" => 101},
          %{"graph_max_inflight" => 17}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end
end
