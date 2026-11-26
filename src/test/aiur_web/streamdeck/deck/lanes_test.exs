defmodule AiurWeb.Streamdeck.Deck.LanesTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index
  alias Aiur.Config.Schema.Lane
  alias AiurWeb.Build.Payload
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Input, Lanes, Nav}
  alias AiurWeb.Streamdeck.FrameUpdates

  test "remaining descending, label ties, and unknown counts render last without zero" do
    window = window()
    section = Lanes.read(window: {:ok, window})
    assert Enum.map(section.keys, & &1.title) == ["Docs", "UI", "CI"]
    assert Enum.map(section.keys, &{&1.remaining, &1.of, &1.pct}) == [{12, "12/15", 20}, {12, "12/42", 71}, {:unknown, "—", nil}]
    unknown = Enum.find(frame(section).keys, &(&1 && &1.label =~ "history incomplete"))
    assert unknown.svg =~ "—"
    assert unknown.svg =~ "history incomplete"
    refute unknown.svg =~ "progress-fill"
    refute unknown.label =~ "0 remaining"
    assert List.last(section.keys).remaining == :unknown
    assert Lanes.read(window: {:ok, Jason.decode!(Jason.encode!(window))}) == section
    changed = put_in(window, [:lane_progress, "ui", :open], 13)
    assert Enum.map(Lanes.read(window: {:ok, changed}).keys, & &1.id) == ~w(ui docs ci)
  end

  test "no configured lanes renders setting guidance without count keys; failed reads stay unavailable" do
    section = Lanes.read(window: {:ok, %{lanes: %{"unsorted" => %{label: "Unsorted"}}, lane_progress: %{}}})
    assert section.keys == []
    assert section.message == "No lanes configured. Define build_order.lanes"
    frame = frame(section)
    assert hd(frame.strip).svg =~ "No lanes"
    assert hd(frame.strip).label =~ "build_order.lanes"
    refute hd(frame.strip).label =~ "0 remaining"
    assert Enum.all?(frame.keys, &is_nil/1)
    assert Lanes.read(window: {:error, :offline}) == %{status: "unavailable", keys: [], message: "Lanes unavailable"}
  end

  test "configured lanes with no members share Build's empty state while unknown membership retains rows" do
    window = window()
    progress = Map.new(window.lane_progress, fn {id, _} -> {id, %{closed: 0, open: 0, total: 0}} end)
    empty = Lanes.read(window: {:ok, %{window | lane_progress: progress}})
    assert empty.keys == []
    assert empty.message == "No lanes configured. Define build_order.lanes"
    frame = frame(empty)
    assert hd(frame.strip).label =~ "No lanes configured"
    refute hd(frame.strip).label =~ "0 remaining"

    progress = Map.put(progress, "ci", %{closed: nil, open: nil, total: nil})
    unknown = Lanes.read(window: {:ok, %{window | lane_progress: progress}})
    assert Enum.map(unknown.keys, & &1.id) == ~w(docs ui ci)
    assert List.last(unknown.keys).remaining == :unknown
    assert unknown.message == nil
  end

  test "real index membership drills into feature-owned tickets and long press returns" do
    ui = %Lane{key: "ui", label: "UI", labels: [" AREA:UI "], hue: 120, icon: "pen"}
    docs = %Lane{key: "docs", label: "Docs", labels: ["area:docs"], hue: 240, icon: "docs"}
    p = parts([row(1, %{labels: [" Area:Ui "]}), row(2, %{labels: ["area:ui", "area:docs"]}), row(3)])
    feature = %{slug: "deck", label: "Deck", hue: 175, epics: [%{key: "f-deck", label: "Deck"}], from: now(), to: :none, baseline: :none}
    p = put_in(p, [:settings], {:ok, put_in(elem(p.settings, 1), [:build_order, :lanes], [ui, docs])})

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
    refute Map.has_key?(Payload.scrub(index.all["1"]), "general_epics")
    section = index |> Index.base() |> Index.window("Etc/UTC", now()) |> then(&Lanes.read(window: {:ok, &1}))
    sections = Deck.navigation(%{lanes: section.keys})
    ui_index = Enum.find_index(sections.lane, &(&1.id == "ui"))
    {nav, []} = Input.reduce(%Nav{view: :lane}, %{"kind" => "key_press", "index" => ui_index}, sections)
    assert nav.stack == [lane: "ui"]
    assert Enum.sort(Enum.map(Enum.find(section.keys, &(&1.id == "ui")).tickets, & &1.id)) == ~w(1 2)
    assert {_, [{:open_ticket, id}]} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    assert id in ~w(1 2)
    assert {%Nav{stack: []}, []} = Input.reduce(nav, %{"kind" => "dial_long_press", "index" => 3}, sections)
  end

  defp frame(section) do
    {_nav, _model, images} = FrameUpdates.frame(%Nav{view: :lane}, %{lanes: section.keys, lanes_message: section.message}, %{})
    images
  end

  defp window do
    epics = Map.new([{"ui", "UI"}, {"docs", "Docs"}, {"ci", "CI"}], fn {key, label} -> {key, %{label: label, general: true}} end)

    %{
      lanes: Map.put(epics, "f-deck", %{label: "Feature", feature: "deck"}),
      lane_progress: %{
        "ui" => %{closed: 30, open: 12, total: 42},
        "docs" => %{closed: 3, open: 12, total: 15},
        "ci" => %{closed: nil, open: nil, total: nil, reason: "history incomplete"}
      }
    }
  end
end
