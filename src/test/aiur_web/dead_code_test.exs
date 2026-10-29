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

  test "retired Units board components are absent while shared modal contracts remain" do
    refute Code.ensure_loaded?(AiurWeb.OperatorControlCenter.UnitsTable)
    refute Code.ensure_loaded?(AiurWeb.OperatorControlCenter.UnitsFilters)
    refute Code.ensure_loaded?(AiurWeb.OperatorControlCenter.ConversationDrawer)

    for module <- [
          AiurWeb.OperatorControlCenter.UnitsPresenter,
          Aiur.Projections.UnitsPolicy,
          Aiur.Projections.UnitsRow,
          AiurWeb.OperatorControlCenter.UnitsPresentation,
          AiurWeb.OperatorControlCenter.UnitsControlPolicy,
          AiurWeb.OperatorControlCenter.UnitsURL,
          AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter
        ] do
      assert Code.ensure_loaded?(module)
    end

    Code.ensure_loaded!(AiurWeb.OperatorControlCenter.AgentLogModal)

    for {function, arity} <- [build: 2, find_running_entry: 2, format_error: 1, composer: 2] do
      assert function_exported?(AiurWeb.OperatorControlCenter.AgentLogModal, function, arity)
    end
  end
end
