defmodule Aiur.BuildOrder.IconTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Icon

  test "maps every normalized lane and status deterministically with generic fallbacks" do
    assert Enum.map(~w(plan-graph runtime dashboard-ui accounting platform), &Icon.lane/1)
           |> Enum.map(& &1.key) == [
             :lane_plan_graph,
             :lane_runtime,
             :lane_dashboard_ui,
             :lane_accounting,
             :lane_platform
           ]

    assert Enum.map([:ready, :blocking, :terminal_unsatisfied, :unknown, :cyclic], &Icon.status/1)
           |> Enum.map(& &1.key) == [
             :status_ready,
             :status_blocking,
             :status_terminal_unsatisfied,
             :status_unknown,
             :status_cyclic
           ]

    assert Icon.lane(:unknown) == %Icon{key: :lane_generic, text: "Build lane unavailable"}
    assert Icon.status(:unexpected) == %Icon{key: :status_generic, text: "Status unavailable"}
  end
end
