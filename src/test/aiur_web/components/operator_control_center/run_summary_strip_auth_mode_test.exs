defmodule AiurWeb.OperatorControlCenter.RunSummaryStripAuthModeTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenter.RunSummaryStripFixtures

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  test "unknown GitHub auth mode stays unknown when a quota snapshot omits it" do
    github_quota = %{state: :observed, windows: %{}, attribution: []}

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: DateTime.utc_now()
      })

    assert html =~ "Auth unknown"
    refute html =~ "GitHub App"
  end
end
