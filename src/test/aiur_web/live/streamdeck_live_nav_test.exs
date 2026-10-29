defmodule AiurWeb.StreamdeckLiveNavTest do
  use AiurWeb.StreamdeckLiveCase
  alias Aiur.TestSupport.BuildHome.UsageInputs
  alias Aiur.TestSupport.EndpointStubs

  test "emulator dial reaches provider meter keys and refresh keeps the meter page", %{meter_agent: meter_agent} do
    now = DateTime.utc_now()

    meters =
      Map.new(Agent.get(meter_agent, & &1), fn {provider, meter} ->
        windows =
          Map.new(meter["windows"], fn {name, window} ->
            {name,
             UsageInputs.window(window["used_percent"], if(name == "session", do: 300, else: 10_080), %{
               resets_at: DateTime.add(now, 3600),
               coverage: :supported
             })}
          end)

        family = String.to_existing_atom(provider)

        {family,
         UsageInputs.snapshot(family, windows, %{
           observed_at: now,
           provider_account_generation: "live-test-generation",
           identity_scope: :account,
           summary_label: "test meter"
         })}
      end)

    EndpointStubs.put(
      streamdeck_usage_load_fun: fn _, _ ->
        UsageInputs.inputs(%{families: Map.keys(meters), meters: meters})
      end
    )

    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    for expected <- [:feature, :epic, :fleet] do
      render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "press"})
      assert nav(view).view == expected
    end

    render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})

    assert nav(view).pages.fleet == 1
    assert render(view) =~ "data-streamdeck-key=\"0\""
    assert render(view) =~ "usage"
    assert render(view) =~ "Fleet · 2"

    send(view.pid, :streamdeck_fixture_fleet_changed)
    render(view)

    assert nav(view).pages.fleet == 1
    assert render(view) =~ "data-streamdeck-key=\"0\""
    assert render(view) =~ "usage"
    assert render(view) =~ "Fleet · 2"
  end

  test "existing emulator events update its own reducer state" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    {:ok, other, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "input", %{"kind" => "dial_press", "index" => 3})
    assert nav(view).view == :feature
    assert nav(other).view == :ticket
    render_hook(view, "grid-page", %{"page" => 1})
    render_hook(view, "dial-long-press", %{"index" => 3})
    assert nav(view).stack == []

    for _ <- 1..3,
        do: render_hook(view, "input", %{"kind" => "dial_press", "index" => 3})

    render_hook(view, "key-press", %{"identifier" => "1352"})
    assert nav(view).selected == "1352"
  end

  test "legacy grid cycle pages without changing the shared view" do
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "grid-page", %{"action" => "cycle"})
    render_hook(view, "dial-press", %{"index" => 3, "action" => "cycle-window"})
    assert nav(view).view == :ticket
    assert nav(view).pages.ticket == 1
  end

  test "legacy selection resolves the identifier against the shared server list", %{
    snapshot_agent: snapshot
  } do
    Agent.update(snapshot, fn _ -> fleet_snapshot(9) end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    render_hook(view, "grid-page", %{"page" => 1})
    assert nav(view).pages.ticket == 1
    render_hook(view, "key-press", %{"identifier" => "fleet-3"})
    assert nav(view).selected == "fleet-3"
    assert :sys.get_state(view.pid).socket.assigns.deck_effects == [{:open_ticket, "fleet-3"}]
  end

  test "browser feature keys use physical positions and open the drilled ticket without pausing" do
    alias Aiur.TestSupport.EndpointStubs
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, feature_window()} end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")

    render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "press"})
    assert nav(view).view == :feature
    key = element(view, ~s([data-streamdeck-key="1"]))
    assert render(key) =~ "Parent 3"
    assert render(key) =~ "phx-click="
    assert render(key) =~ "&quot;kind&quot;:&quot;key&quot;"
    render_click(key)
    assert nav(view).stack == [{:feature, "parent3"}]
    assert has_element?(view, ~s([data-streamdeck-key="0"]), "Member 3")

    render_click(element(view, ~s([data-streamdeck-key="0"])))
    assert nav(view).selected == "103"
    assert streamdeck_assigns(view).deck_effects == [{:open_ticket, "103"}]
    assert streamdeck_assigns(view).sd_mode == :cmd
    assert streamdeck_assigns(view).sd_active.identifier == "103"
    refute_received {:streamdeck_pause, _}
    refute_received {:streamdeck_resume, _}
  end

  test "browser dial D pages features, holds back from a drill and cycles all views" do
    alias Aiur.TestSupport.EndpointStubs
    EndpointStubs.put(streamdeck_build_window_fun: fn _, _, _ -> {:ok, feature_window()} end)
    {:ok, view, _html} = live(build_conn(), "/streamdeck")
    press = %{"kind" => "dial", "index" => 3, "action" => "press"}
    render_hook(view, "input", press)
    render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1})
    assert nav(view).view == :feature
    assert nav(view).pages.feature == 1
    assert streamdeck_assigns(view).grid_dial_value > 0
    assert has_element?(view, ~s([data-streamdeck-key="0"]), "Parent 9")
    render_click(element(view, ~s([data-streamdeck-key="0"])))
    assert nav(view).stack == [{:feature, "parent9"}]
    render_hook(view, "input", %{"kind" => "dial", "index" => 3, "action" => "long_press"})
    assert nav(view).stack == []
    assert nav(view).pages.feature == 1
    assert has_element?(view, ~s([data-streamdeck-key="0"]), "Parent 9")

    for expected <- [:epic, :fleet, :ticket] do
      render_hook(view, "input", press)
      assert nav(view).view == expected
    end
  end

  defp feature_window do
    slugs = Enum.map(1..10, &"parent#{&1}")
    lanes = Enum.map(1..10, &"lane#{&1}")

    rows =
      Enum.map(1..10, fn n ->
        %{id: "#{100 + n}", num: 100 + n, title: "Member #{n}", sec: "plan", epic: "lane#{n}", qpos: n}
      end)

    %{
      sources: %{agents: %{state: "ok"}},
      sections: %{now: [], plan: [%{id: "1", num: 1, title: "Outsider", sec: "plan", epic: "other", qpos: 0} | rows], nq: []},
      order: lanes,
      epics: Map.new(Enum.zip(lanes, slugs), fn {lane, slug} -> {lane, %{feature: slug}} end),
      features: Map.new(1..10, fn n -> {"parent#{n}", %{label: "Parent #{n}", epics: ["lane#{n}"]}} end),
      feature_progress: %{features: Map.new(1..10, fn n -> {"lane#{n}", %{feature: "parent#{n}", closed: 1, open: 1, ci_wait: 0, unpublished: 0, total: 2}} end)}
    }
  end

  defp nav(view), do: :sys.get_state(view.pid).socket.assigns.deck_nav
end
