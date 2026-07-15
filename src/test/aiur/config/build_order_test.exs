defmodule Aiur.Config.BuildOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "uses bounded ticket-detail cache defaults" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_freshness_ms == 30_000
    assert settings.build_order.ticket_detail_max_entries == 32
    assert settings.build_order.ticket_detail_max_description_bytes == 16_384
  end

  test "accepts explicit ticket-detail cache bounds" do
    assert {:ok, settings} =
             Schema.parse(%{
               "build_order" => %{
                 "ticket_detail_freshness_ms" => 10_000,
                 "ticket_detail_max_entries" => 12,
                 "ticket_detail_max_description_bytes" => 4_096
               }
             })

    assert settings.build_order.ticket_detail_freshness_ms == 10_000
    assert settings.build_order.ticket_detail_max_entries == 12
    assert settings.build_order.ticket_detail_max_description_bytes == 4_096
  end

  test "rejects unbounded or nonpositive ticket-detail cache configuration" do
    for attrs <- [
          %{"ticket_detail_freshness_ms" => 300_001},
          %{"ticket_detail_max_entries" => 101},
          %{"ticket_detail_max_description_bytes" => 16_385},
          %{"ticket_detail_freshness_ms" => 0}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end
end
