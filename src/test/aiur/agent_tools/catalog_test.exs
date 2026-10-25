defmodule Aiur.AgentTools.CatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentTools.Catalog

  describe "future regression guard for the pre-move catalog (not move coverage)" do
    test "catalog specs retain their ordered names and schema fields" do
      assert Catalog.names() == [
               "linear_graphql",
               "aiur_reply_review_thread",
               "aiur_resolve_review_thread",
               "emit_alert",
               "emit_event",
               "aiur_subscribe",
               "aiur_unsubscribe",
               "aiur_declare_blocker",
               "aiur_unblock",
               "aiur_set_ticket_state",
               "aiur_set_epic",
               "aiur_feature"
             ]

      for spec <- Catalog.specs() do
        assert Map.has_key?(spec, "name")
        assert Map.has_key?(spec, "description")
        assert Map.has_key?(spec, "inputSchema")
      end
    end
  end
end
