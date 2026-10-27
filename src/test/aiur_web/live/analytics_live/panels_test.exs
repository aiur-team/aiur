defmodule AiurWeb.AnalyticsLive.PanelsTest do
  use Aiur.TestSupport
  import Phoenix.LiveViewTest
  import AiurWeb.AnalyticsLiveFixtures
  alias Aiur.TestSupport.AwaitingCommands
  @fixtures Path.expand("../../../fixtures/run_telemetry", __DIR__)
  setup :setup_analytics

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "carries the awaiting-Commands banner into Analytics" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    assert html =~ "2 units awaiting commands"
    assert html =~ "decisions-banner"
    assert html =~ ~s(href="/commands")
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "re-reads the awaiting count on a Command signal and on its own tick" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)
    store = AiurWeb.EndpointConfig.get(:decision_store)

    {:ok, view, html} = loaded_live(build_conn(), "/analytics")
    assert html =~ "2 units awaiting commands"

    # A best-effort broadcast is the fast path.
    :ok = AwaitingCommands.put_counts(store, open: 1, awaiting: 1, blocking: 0, awaiting_blocking: 0)
    send(view.pid, {:decision_changed, "dec-1", 2})
    assert render(view) =~ "1 unit awaiting commands"

    # The tick is the safety net for a broadcast that never arrives: without it
    # this page would keep showing a count the Commands page has moved past.
    :ok = AwaitingCommands.put_counts(store, open: 0, awaiting: 0)
    send(view.pid, :awaiting_commands_tick)
    refute render(view) =~ "units awaiting commands"
  end

  @tag awaiting_commands: %{total: 4, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0}
  test "omits the awaiting-Commands banner when nothing is waiting" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, _view, html} = loaded_live(build_conn(), "/analytics")

    refute html =~ "units awaiting commands"
    refute html =~ "decisions-banner"
  end

  @tag awaiting_commands: %{total: 3, open: 2, blocking: 1, deferred: 0, awaiting: 2, awaiting_blocking: 1}
  test "survives every message the Command topic carries" do
    Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)

    {:ok, view, html} = loaded_live(build_conn(), "/analytics")
    assert html =~ "2 units awaiting commands"

    assert AwaitingCommands.render_after_command_topic(view) =~ "2 units awaiting commands"
  end

  # --- rtk output-compression panel -----------------------------------------

  describe "agent output compression panel" do
    setup do
      Application.put_env(:aiur, :analytics_telemetry_file, @fixtures)
      previous = Application.get_env(:aiur, :analytics_rtk_opts)
      on_exit(fn -> reset_env(:analytics_rtk_opts, previous) end)
      :ok
    end

    defp render_rtk_panel(rtk_opts) do
      Application.put_env(:aiur, :analytics_rtk_opts, rtk_opts)
      {:ok, _view, html} = loaded_live(build_conn(), "/analytics")
      html
    end

    defp rtk_runner(responses), do: fn _rtk, args -> Map.fetch!(responses, args) end

    defp admitted_rtk(gain_response) do
      [
        enabled?: true,
        rtk_path: "/usr/bin/rtk",
        runner:
          rtk_runner(%{
            ["--version"] => {"rtk 0.47.0\n", 0},
            ["hook", "check", "gh pr view 1"] => {"No rewrite for: gh pr view 1\n", 1},
            ["gain", "-f", "json"] => gain_response
          })
      ]
    end

    defp gain_json(summary), do: {Jason.encode!(%{"summary" => summary}), 0}

    test "reports the recorded saving" do
      html =
        render_rtk_panel(
          admitted_rtk(
            gain_json(%{
              "total_commands" => 2,
              "total_input" => 469,
              "total_output" => 106,
              "total_saved" => 363,
              "avg_savings_pct" => 77.39872068230277
            })
          )
        )

      assert html =~ "Agent output compression"
      assert html =~ ~s(class="an-rtk-val")
      assert html =~ "77.4%"
      assert html =~ "469"
      assert html =~ "363"
    end

    # An empty rtk history reports `total_commands: 0` beside
    # `avg_savings_pct: 0.0`. The panel must say so in words: "0%" would claim
    # rtk filtered agent output and removed none of it.
    test "says no commands were filtered instead of rendering 0%" do
      html =
        render_rtk_panel(
          admitted_rtk(
            gain_json(%{
              "total_commands" => 0,
              "total_input" => 0,
              "total_output" => 0,
              "total_saved" => 0,
              "avg_savings_pct" => 0.0
            })
          )
        )

      assert html =~ "No commands filtered yet"
      assert html =~ "no saving to report"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "says rtk is off rather than showing an empty chart" do
      html = render_rtk_panel(enabled?: false)

      assert html =~ "Savings reporting is off"
      assert html =~ "agent.rtk.enabled"
      assert html =~ "this does not control a host-wide hook"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "says rtk is missing when it is enabled but not installed" do
      html = render_rtk_panel(enabled?: true, rtk_path: nil)

      assert html =~ "rtk is not installed"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    # The operator has to be able to see that the probe detected a risky
    # host-wide hook; the report does not disable or block that hook.
    test "reports a gh rewrite without implying the hook was disabled" do
      opts = [
        enabled?: true,
        rtk_path: "/usr/bin/rtk",
        runner:
          rtk_runner(%{
            ["--version"] => {"rtk 0.47.0\n", 0},
            ["hook", "check", "gh pr view 1"] => {"rtk gh pr view 1\n", 0}
          })
      ]

      html = render_rtk_panel(opts)

      assert html =~ "rtk gh rewrite detected"
      assert html =~ "would rewrite"
      assert html =~ "applies regardless of `agent.rtk.enabled`"
      assert html =~ "this report does not disable the hook"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end

    test "reports an unreadable summary as unknown rather than zero" do
      html = render_rtk_panel(admitted_rtk({"not json", 0}))

      assert html =~ "Savings could not be read"
      assert html =~ "unknown rather than zero"
      # The class name also appears in the page's inlined stylesheet, so the
      # assertion has to look for the rendered element, not the string.
      refute html =~ ~s(class="an-rtk-val")
    end
  end
end
