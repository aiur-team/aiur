defmodule Aiur.BuildOrder.CadenceTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Cadence
  alias Aiur.Config.Schema

  describe "derivation from the tracker poll interval" do
    # The concrete case this change exists for. #2064 moved the tracker to 120s
    # and the shipped constants stayed put, so the page kept re-reading a graph
    # that could not have moved.
    test "at a 120s poll interval the derived values match the tracker" do
      assert %{
               graph_catalog_refresh_ms: 120_000,
               graph_catalog_labels_refresh_ms: 600_000,
               ticket_detail_freshness_ms: 30_000
             } = Cadence.derive(120)
    end

    test "the cadences follow the poll interval rather than staying put" do
      slow = Cadence.derive(120)
      fast = Cadence.derive(5)

      assert fast.graph_catalog_refresh_ms < slow.graph_catalog_refresh_ms
    end

    # The two settings by which viewing bought reads are not derived here because
    # they no longer exist. Deriving a better number for them would have kept the
    # page paying for being open; the fix was to delete them. This test is the
    # guard against a later change quietly reintroducing one.
    test "no viewer-driven cadence is derived" do
      derived = Cadence.derive(120)

      refute Map.has_key?(derived, :graph_selected_refresh_ms)
      refute Map.has_key?(derived, :graph_demand_refresh_ms)
    end

    # The labelled catalog read costs 26 points per page against the cheap read's
    # 1 (#1766), and the schema rejects a labels cadence faster than the catalog
    # poll it rides on — so a derived default must never be one the schema
    # itself would refuse.
    test "derived values always satisfy the schema's own cross-field rules" do
      for interval <- [1, 5, 30, 120, 600, 3_600, 86_400] do
        derived = Cadence.derive(interval)

        assert derived.graph_catalog_labels_refresh_ms >= derived.graph_catalog_refresh_ms

        assert {:ok, _settings} =
                 Schema.parse(%{
                   "build_order" => %{
                     "graph_catalog_refresh_ms" => derived.graph_catalog_refresh_ms,
                     "graph_catalog_labels_refresh_ms" => derived.graph_catalog_labels_refresh_ms,
                     "ticket_detail_freshness_ms" => derived.ticket_detail_freshness_ms
                   }
                 })
      end
    end

    # This is read on the way to starting a supervised process. A nonsense
    # interval should slow the page down, not stop it booting.
    test "a nonsensical poll interval degrades rather than raises" do
      for interval <- [0, -1, nil, "120", :bad] do
        assert %{graph_catalog_refresh_ms: ms} = Cadence.derive(interval)
        assert is_integer(ms) and ms > 0
      end
    end
  end

  describe "resolve/3" do
    test "an explicit setting always beats the derivation" do
      assert Cadence.resolve(:graph_catalog_refresh_ms, 7_000, 120) == 7_000
    end

    test "an unset setting falls back to the derived value" do
      assert Cadence.resolve(:graph_catalog_refresh_ms, nil, 120) == 120_000
    end

    # A stored zero or negative is not a deliberate setting, it is a broken one,
    # and honouring it would mean a refresh loop with no interval.
    test "a nonpositive setting is treated as unset" do
      assert Cadence.resolve(:graph_catalog_refresh_ms, 0, 120) == 120_000
      assert Cadence.resolve(:graph_catalog_refresh_ms, -5, 120) == 120_000
    end
  end
end
