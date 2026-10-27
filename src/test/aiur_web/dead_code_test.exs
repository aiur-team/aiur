defmodule AiurWeb.DeadCodeTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Overview

  test "fleet table and filters are retired" do
    refute Code.ensure_loaded?(AiurWeb.OperatorControlCenter.FleetTable)
    refute Code.ensure_loaded?(AiurWeb.OperatorControlCenter.FleetFilters)
  end

  test "Overview retains the live banners without the retired exports" do
    Code.ensure_loaded!(Overview)
    refute function_exported?(Overview, :fleet_overview, 1)
    refute function_exported?(Overview, :readonly_banner, 1)
    assert function_exported?(Overview, :decisions_banner, 1)
    assert function_exported?(Overview, :error, 1)
  end
end
