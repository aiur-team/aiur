defmodule AiurWeb.OperatorControlCenter.AgentUsageSnapshotTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.Agent.UsageSnapshot
  alias AiurWeb.OperatorControlCenter.AgentUsageSnapshot

  test "renders unknown token measurements as unknown instead of zero" do
    unknown = {:unknown, :not_reported}

    snapshot = %UsageSnapshot{
      agent_id: "agent-1",
      backend: :codex,
      context_occupancy: nil,
      cumulative_metrics: %{
        input: unknown,
        output: unknown,
        cached_input: unknown,
        uncached_input: unknown,
        cached_proportion: unknown
      },
      scope: :attempt,
      scope_id: "attempt-1",
      observed_at: nil,
      freshness_assessment: :unknown
    }

    html =
      render_component(&AgentUsageSnapshot.agent_usage_snapshot/1, %{
        snapshot: snapshot,
        context_occupancy: nil,
        error: nil
      })

    assert html =~ "Input tokens"
    assert html =~ "Output tokens"
    assert html =~ "Observation age: unknown freshness"
    assert html =~ "Current attempt (attempt-1)"
    assert html =~ "—"
    refute html =~ ~s(class="metric-value">0</span>)
    refute html =~ "0.0%"
  end
end
