defmodule AiurWeb.OperatorControlCenter.FleetContextTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.FleetTable

  test "fleet rows render known and unknown context distinctly" do
    fleet = %{
      running: [
        row("KNOWN", %{used_tokens: 150, window_tokens: 300, pressure: :normal}),
        row("UNKNOWN", %{used_tokens: 150, window_tokens: nil, pressure: :warning}),
        row("ABSENT", nil)
      ],
      retrying: [],
      idle: []
    }

    html = render_component(&FleetTable.fleet_table/1, %{fleet: fleet, now: ~U[2026-09-27 12:00:00Z]})
    assert html =~ ~s|data-label="Context">150 / 300 tokens (50%)|
    assert html =~ ~s|data-label="Context">150 tokens / unknown capacity · warning|
    assert html =~ ~s|data-label="Context">—</td>|
  end

  defp row(identifier, context) do
    %{issue_identifier: identifier, title: identifier, state: "in-progress", work_state: :working, waiting_reason: :active, runtime_seconds: 60, open_decision_count: 0, context_usage: context}
  end
end
