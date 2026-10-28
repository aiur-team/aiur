defmodule AiurWeb.Streamdeck.Deck.EpicsTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index
  alias Aiur.Config.Schema.GeneralEpic
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Epics, Input, Nav}
  alias AiurWeb.Streamdeck.Render

  test "remaining descending, label ties, and unknown counts render last without zero" do
    window = window()
    section = Epics.read(window: {:ok, window})
    assert Enum.map(section.keys, & &1.title) == ["Docs", "UI", "CI"]
    assert Enum.map(section.keys, &{&1.remaining, &1.of, &1.pct}) == [{12, "12/15", 20}, {12, "12/42", 71}, {:unknown, "—", nil}]
    [_, _, unknown] = Render.frame(%{grid: %{epics: section.keys}, nav: %Nav{view: :epic}}).keys |> Enum.take(3)
    assert unknown.svg =~ "—"
    assert unknown.svg =~ "history incomplete"
    refute unknown.svg =~ "progress-fill"
    refute unknown.label =~ "0 remaining"
    assert List.last(section.keys).remaining == :unknown
    assert Epics.read(window: {:ok, Jason.decode!(Jason.encode!(window))}) == section
    changed = put_in(window, [:epic_progress, "ui", :open], 13)
    assert Enum.map(Epics.read(window: {:ok, changed}).keys, & &1.id) == ~w(ui docs ci)
  end

  test "no configured epics renders setting guidance without count keys; failed reads stay unavailable" do
    section = Epics.read(window: {:ok, %{epics: %{"unsorted" => %{label: "Unsorted"}}, epic_progress: %{}}})
    assert section.keys == []
    assert section.message == "No epics configured. Define build_order.general_epics"
    frame = Render.frame(%{grid: %{epics: [], epics_message: section.message}, nav: %Nav{view: :epic}})
    assert hd(frame.keys).svg =~ "No epics"
    assert hd(frame.strip).label =~ "build_order.general_epics"
    refute hd(frame.keys).label =~ "0 remaining"
    assert Enum.all?(tl(frame.keys), &is_nil/1)
    assert Epics.read(window: {:error, :offline}) == %{status: "unavailable", keys: [], message: "Epics unavailable"}
  end

  test "real index membership drills into feature-owned tickets and long press returns" do
    ui = %GeneralEpic{key: "ui", label: "UI", labels: [" AREA:UI "], hue: 120, icon: "pen"}
    docs = %GeneralEpic{key: "docs", label: "Docs", labels: ["area:docs"], hue: 240, icon: "docs"}
    p = parts([row(1, %{labels: [" Area:Ui "]}), row(2, %{labels: ["area:ui", "area:docs"]}), row(3)])
    feature = %{slug: "deck", label: "Deck", hue: 175, epics: [%{key: "f-deck", label: "Deck"}], from: now(), to: :none, baseline: :none}
    p = put_in(p, [:settings], {:ok, put_in(elem(p.settings, 1), [:build_order, :general_epics], [ui, docs])})

    p =
      put_in(
        p,
        [:features],
        {:ok, %{features: %{"deck" => feature}, owners: %{1 => %{feature: "deck", epic: "f-deck", joined_at: DateTime.from_unix!(now(), :millisecond)}}, also: %{}, health: health()}}
      )

    assert {:ok, index} = assemble(p)
    assert index.all["1"].epic == "f-deck"
    assert index.all["1"].general_epics == ["ui"]
    assert index.all["2"].general_epics == ["ui", "docs"]
    section = index |> Index.base() |> Index.window("Etc/UTC", now()) |> then(&Epics.read(window: {:ok, &1}))
    sections = Deck.navigation(%{epics: section.keys})
    ui_index = Enum.find_index(sections.epic, &(&1.id == "ui"))
    {nav, []} = Input.reduce(%Nav{view: :epic}, %{"kind" => "key_press", "index" => ui_index}, sections)
    assert nav.stack == [epic: "ui"]
    assert Enum.sort(Enum.map(Enum.find(section.keys, &(&1.id == "ui")).tickets, & &1.id)) == ~w(1 2)
    assert {_, [{:open_ticket, id}]} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    assert id in ~w(1 2)
    assert {%Nav{stack: []}, []} = Input.reduce(nav, %{"kind" => "dial_long_press", "index" => 3}, sections)
  end

  test "label memberships travel in strict Build payloads while older rows remain valid" do
    alias Aiur.TestSupport.BuildHome.FixtureSource
    alias AiurWeb.Build.Payload
    {:ok, data} = FixtureSource.full(dataset: "live")
    snapshot = Payload.snapshot(data, "epic-test", 0)
    # Compatibility guard: existing fixture rows intentionally omit the optional field.
    assert Payload.validate(snapshot) == :ok
    [row | rest] = snapshot["sections"]["now"]
    updated = put_in(snapshot, ["sections", "now"], [Map.put(row, "general_epics", ["bugs"]) | rest])
    assert Payload.validate(updated) == :ok
    assert hd(updated["sections"]["now"])["general_epics"] == ["bugs"]
  end

  defp window do
    epics = Map.new([{"ui", "UI"}, {"docs", "Docs"}, {"ci", "CI"}], fn {key, label} -> {key, %{label: label, general: true}} end)

    %{
      epics: Map.put(epics, "f-deck", %{label: "Feature", feature: "deck"}),
      epic_progress: %{
        "ui" => %{closed: 30, open: 12, total: 42},
        "docs" => %{closed: 3, open: 12, total: 15},
        "ci" => %{closed: nil, open: nil, total: nil, reason: "history incomplete"}
      }
    }
  end
end
