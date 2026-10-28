defmodule AiurWeb.Streamdeck.Deck.FeaturesTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.{Deck, Render}
  alias AiurWeb.Streamdeck.Deck.{Features, Input, Nav}

  test "snapshot order, percentages, layers, badges and age reach the rendered frame" do
    [a, b] = Features.read(window: {:ok, window()}, now: 180_000).keys
    assert a.key == "parent"
    assert a.pct == 60
    assert a.bar == %{closed: 12, open: 3, ci_wait: 2, unpublished: 3, total: 20}
    assert a.ci_wait == 2
    assert b.pct == 0
    assert b.ci_wait == nil
    frame = frame([a, b])
    assert hd(frame.keys).svg =~ ">60%</text>"
    assert hd(frame.keys).svg =~ ">CI 2</text>"
    assert hd(frame.keys).svg =~ ~s(data-layer="unpublished")
    assert Enum.at(frame.keys, 1).svg =~ ">0%</text>"
    refute Enum.at(frame.keys, 1).svg =~ ">CI "
    assert hd(frame.strip).svg =~ "12/20 closed · 3 not published · age 2m"
  end

  test "missing counts preserve closed-total percentage parity and keep incomplete bars unknown" do
    for count <- [:closed, :open, :ci_wait, :unpublished, :total] do
      window = put_in(window(), [:feature_progress, :features, "home", count], nil)
      window = put_in(window, [:feature_progress, :features, "home", :reason], "states unavailable")
      [key | _] = Features.keys(window, 180_000)
      expected_pct = if count in [:closed, :total], do: :unknown, else: 60
      assert key.pct == expected_pct
      assert key.bar == :unknown
      face = hd(frame([key]).keys)

      if expected_pct == :unknown do
        assert face.svg =~ ">—</text>"
        assert face.svg =~ "states unavailable"
      else
        assert face.svg =~ ">60%</text>"
      end

      refute face.svg =~ ">0%</text>"
      refute face.svg =~ ~s(data-layer="closed")
      if count == :ci_wait, do: assert(key.ci_wait == nil)
    end
  end

  test "feature paging drills by epic membership and long press restores the feature page" do
    window = window()
    entries = Map.new(1..9, fn i -> {"lane#{i}", %{window.feature_progress.features["home"] | feature: "parent#{i}"}} end)
    catalogue = Map.new(1..9, fn i -> {"parent#{i}", %{label: "Parent #{i}", epics: ["lane#{i}"]}} end)
    rows = put_in(window.sections, [:now, Access.at(0), :epic], "lane9")
    rows = put_in(rows, [:plan, Access.at(0), :epic], "lane9")

    window = %{
      window
      | epics: Map.new(1..9, &{"lane#{&1}", %{feature: "parent#{&1}"}}),
        features: catalogue,
        sections: rows,
        feature_progress: %{window.feature_progress | features: entries},
        order: Enum.map(1..9, &"lane#{&1}")
    }

    keys = Features.keys(window, 180_000)
    sections = Deck.navigation(%{features: keys})
    {nav, []} = Input.reduce(%Nav{view: :feature}, %{"kind" => "dial_turn", "index" => 3, "ticks" => 1}, sections)
    assert Enum.count(frame(keys, nav).keys, & &1) == 1
    {drill, []} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    assert drill.stack == [{:feature, "parent9"}]
    assert Enum.map(List.last(keys).tickets, & &1.id) == ["1", "2"]
    assert hd(frame(keys, drill).keys).label =~ "Member one"
    assert Enum.at(frame(keys, drill).keys, 1).label =~ "Member two"
    {_, effects} = Input.reduce(drill, %{"kind" => "key_press", "index" => 1}, sections)
    assert effects == [{:open_ticket, "2"}]
    {back, []} = Input.reduce(drill, %{"kind" => "dial_long_press", "index" => 3}, sections)
    assert back.stack == []
    assert back.view == :feature
    assert Nav.page(back) == 1
  end

  test "parent percentages and published-open layers match Build aggregation across epics" do
    window = window()
    window = put_in(window, [:features, "parent", :epics], ["home", "cli"])
    window = put_in(window, [:feature_progress, :features, "cli", :feature], "parent")
    window = %{window | features: Map.delete(window.features, "cli-parent")}
    [key] = Features.keys(window, 180_000)
    assert key.label == "Build"
    assert key.pct == 50
    assert key.bar.total == 24
    assert key.bar.open == 7
    assert hd(frame([key]).keys).svg =~ ~s(width="38.25" height="4" fill="#86bfff" data-layer="open")
  end

  test "wire payloads use block age and zero totals and failed reads remain unknown" do
    window = window() |> Jason.encode!() |> Jason.decode!()
    window = put_in(window, ["feature_progress", "features", "home", "total"], 0)
    [key | _] = Features.keys(window, 180_000)
    assert key.pct == :unknown
    assert key.observed_at == 60_000
    assert hd(frame([key]).keys).svg =~ ">—</text>"
    assert Features.read(window: {:error, :offline}) == %{status: "unavailable", keys: []}
    unavailable = Render.frame(%{grid: %{features: [], features_status: "unavailable"}, nav: %Nav{view: :feature}})
    assert hd(unavailable.strip).svg =~ "Features unavailable"
  end

  test "absent progress retains catalogue keys with unknown counts and age" do
    window = %{window() | feature_progress: %{features: %{}}}
    keys = Features.keys(window, 180_000)
    assert Enum.map(keys, & &1.id) == ["cli-parent", "parent"]
    assert Enum.all?(keys, &(&1.pct == :unknown))
    assert hd(frame(keys).keys).svg =~ "Progress unavailable"
    assert hd(frame(keys).strip).svg =~ "—/— closed · — not published · age —"
  end

  test "combined unavailable reasons wrap inside a physical key" do
    window = put_in(window(), [:feature_progress, :features, "home", :closed], nil)
    window = put_in(window, [:feature_progress, :features, "home", :reason], "states unavailable · planned count unavailable")
    [key | _] = Features.keys(window, 180_000)
    svg = hd(frame([key]).keys).svg
    lines = Regex.scan(~r/<text[^>]+font-size="7"[^>]*>([^<]*)<\/text>/, svg, capture: :all_but_first) |> List.flatten()
    assert length(lines) == 3
    assert Enum.all?(lines, &(String.length(&1) <= 24))
    assert Enum.join(lines, " ") == "states unavailable · planned count unavailable"
  end

  test "lanes absent from the epic catalogue do not dilute parent progress" do
    for missing <- [%{}, %{closed: 0, open: 100, ci_wait: 0, unpublished: 0, total: 100}] do
      window = put_in(window(), [:features, "parent", :epics], ["home", "absent"])
      window = put_in(window, [:feature_progress, :features, "absent"], missing)
      [key | _] = Features.keys(window, 180_000)
      assert key.pct == 60
      assert key.bar.total == 20
      assert hd(frame([key]).keys).svg =~ ">60%</text>"
    end
  end

  defp frame(keys, nav \\ %Nav{view: :feature}), do: Render.frame(%{grid: %{features: keys}, nav: nav})

  defp window do
    %{
      order: ["home", "cli"],
      epics: %{"home" => %{feature: "parent"}, "cli" => %{feature: "cli-parent"}},
      features: %{"parent" => %{label: "Build", epics: ["home"]}, "cli-parent" => %{label: "CLI", epics: ["cli"]}},
      feature_progress: %{
        observed_at: 60_000,
        features: %{
          "home" => %{feature: "parent", label: "Home", closed: 12, open: 3, ci_wait: 2, unpublished: 3, total: 20, reason: nil},
          "cli" => %{feature: "cli-parent", label: "CLI", closed: 0, open: 4, ci_wait: 0, unpublished: 0, total: 4}
        }
      },
      sections: %{
        now: [%{id: "1", num: 1, title: "Member one", epic: "home", feature: nil, sec: "now", agent: %{state: "active"}}],
        plan: [
          %{id: "2", num: 2, title: "Member two", epic: "cli", sec: "plan"},
          %{id: "3", num: 3, title: "Outsider", epic: "other", feature: "parent", sec: "plan"}
        ]
      }
    }
  end
end
