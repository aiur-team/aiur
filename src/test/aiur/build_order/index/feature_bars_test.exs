defmodule Aiur.BuildOrder.Index.FeatureBarsTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.Features.LabelRules
  alias Aiur.BuildOrder.History.Row
  alias Aiur.BuildOrder.Index.FeatureBars
  alias Aiur.BuildOrder.Lifecycle

  @now DateTime.to_unix(DateTime.utc_now(), :millisecond)

  defp ago(days), do: DateTime.from_unix!(@now - days * 86_400_000, :millisecond)
  defp open(labels, created \\ 10), do: %Row{lifecycle: %Lifecycle{state: :open, state_reason: :none}, labels: labels, created_at: ago(created)}

  defp closed(labels, reason, extra \\ []),
    do: struct(%Row{lifecycle: %Lifecycle{state: :closed, state_reason: reason}, labels: labels, created_at: ago(20), closed_at: ago(1)}, extra)

  defp parts(rows, opts \\ []) do
    registry = %{
      features: Map.new(Keyword.get(opts, :registry, []), fn {slug, label} -> {slug, %{label: label}} end),
      owners: Keyword.get(opts, :owners, %{}),
      epics: Keyword.get(opts, :epics, [])
    }

    %{history: {:ok, %{rows: rows}}, features: {:ok, registry}, settings: {:ok, %{build_order: %{feature_order: Keyword.get(opts, :order, [])}}}, labels: Keyword.get(opts, :labels)}
  end

  test "labelled tickets form a named feature; merged counts merged PRs and PR-less completions" do
    rows = %{
      1 =>
        closed(["feature:mp-e2"], :completed, merged_at: ago(1), pr_number: 50, label_descriptions: %{"feature:mp-e2" => "Feature collection: MP-E2 Commands (routing, escalation, native questions)"}),
      2 => closed(["feature:mp-e2"], :completed, merged_at: :none, pr_number: :none),
      3 => closed(["feature:mp-e2"], :completed, merged_at: :none, pr_number: 51),
      4 => closed(["feature:mp-e2"], :not_planned),
      5 => open(["feature:mp-e2", "area:ui"]),
      6 => open(["feature:Bad Slug"])
    }

    assert FeatureBars.compute(parts(rows), @now) == [%{key: "mp-e2", label: "Commands", merged: 2, total: 3}]
    history_row = rows[1]
    assert {:ok, "mp-e2"} = history_row.labels |> hd() |> LabelRules.parse()
  end

  test "registry members and labels join under one slug; registry label wins and empty features are hidden" do
    rows = %{1 => closed([], :completed, merged_at: ago(1), pr_number: 9), 2 => open(["feature:bo-7"])}
    parts = parts(rows, registry: [{"bo-7", "BO: Seven"}, {"bo-8", "BO: Empty"}], owners: %{1 => %{feature: "bo-7"}})

    assert FeatureBars.compute(parts, @now) == []
  end

  test "Build Order root labels show the distinguishing suffix" do
    rows = %{1 => open(["feature:bo-7"])}
    parts = parts(rows, registry: [{"bo-7", "BO: Platform program 2026-10 — MP-E1 build queue (wave 0)"}])

    assert FeatureBars.compute(parts, @now) == []
    lettered = parts(rows, registry: [{"bo-7", "BO: Platform program 2026-10 — MP-E8 home page (wave 0b)"}])
    assert FeatureBars.compute(lettered, @now) == []
  end

  test "Build Order roots and their generated epics are not product feature rows" do
    description = "Feature collection: MP-E7 listener modes (steer, sync, async; Executor delivery)"
    root = open(["build-order", "feature:bo-42"], 20) |> Map.put(:number, 42)
    member = open(["feature:mp-e7", "feature:bo-42"], 10) |> Map.put(:number, 43) |> Map.put(:label_descriptions, %{"feature:mp-e7" => description})
    parts = parts(%{42 => root, 43 => member})

    assert FeatureBars.compute(parts, @now) == [%{key: "mp-e7", label: "Listener modes", merged: 0, total: 1}]
  end

  test "the registered MP-E4, MP-E7 and MP-N1..N7 label descriptions name their rows without logical ids" do
    descriptions = %{
      "mp-e4" => "Feature collection: MP-E4 conversations (journal, history API, anchors, conversation view)",
      "mp-e7" => "Feature collection: MP-E7 listener modes (steer, sync, async; Executor delivery)",
      "mp-n1" => "Feature collection: MP-N1 phone app shell (Expo app, native cores, WebView host, distribution)",
      "mp-n2" => "Feature collection: MP-N2 machine-level pairing, gateway and instance discovery",
      "mp-n3" => "Feature collection: MP-N3 phone meta-dashboard of instances",
      "mp-n4" => "Feature collection: MP-N4 end-to-end encrypted push through a relay",
      "mp-n5" => "Feature collection: MP-N5 notification preferences and progress updates",
      "mp-n6" => "Feature collection: MP-N6 contextual Command response on phone and watch",
      "mp-n7" => "Feature collection: MP-N7 watchOS and Wear OS apps"
    }

    rows =
      descriptions
      |> Enum.with_index(1)
      |> Map.new(fn {{slug, description}, index} -> {index, open(["feature:#{slug}"], index) |> Map.put(:label_descriptions, %{"feature:#{slug}" => description})} end)

    labels = FeatureBars.compute(parts(rows), @now) |> Map.new(&{&1.key, &1.label})

    assert labels == %{
             "mp-e4" => "Conversations",
             "mp-e7" => "Listener modes",
             "mp-n1" => "Phone app shell",
             "mp-n2" => "Machine-level pairing, gateway and instance discovery",
             "mp-n3" => "Phone meta-dashboard of instances",
             "mp-n4" => "End-to-end encrypted push through a relay",
             "mp-n5" => "Notification preferences and progress updates",
             "mp-n6" => "Contextual Command response on phone and watch",
             "mp-n7" => "WatchOS and Wear OS apps"
           }
  end

  test "feature display names remove MP-E, MP-N and BO: logical prefixes and title-case the slug fallback" do
    rows = %{
      1 => open(["feature:plain-slug"]),
      2 => open(["feature:mp-e4"], 20),
      3 => open(["feature:mp-n2"], 30),
      4 => open(["feature:streamdeck-redesign"], 40),
      5 => open(["feature:mp-e7"], 50)
    }

    parts =
      parts(rows,
        registry: [
          {"mp-e4", "MP-E1 build queue"},
          {"mp-n2", "MP-N2 machine-level pairing"},
          {"streamdeck-redesign", "BO: Stream Deck Parity"},
          {"mp-e7", "MP-E7"}
        ],
        labels: {:ok, %{1 => %{label_descriptions: %{"feature:mp-e7" => "Feature collection: MP-E7 listener modes (steer, sync, async)"}}}, 0}
      )

    labels = FeatureBars.compute(parts, @now) |> Map.new(&{&1.key, &1.label})

    assert labels == %{
             "mp-e4" => "Build Queue",
             "mp-n2" => "Machine-level Pairing",
             "streamdeck-redesign" => "Stream Deck Parity",
             "plain-slug" => "Plain Slug",
             "mp-e7" => "Listener modes"
           }
  end

  test "a legacy persisted history row decodes without label descriptions" do
    row = %Row{number: 1, observed_at: ago(1)} |> Row.to_json() |> Map.delete("label_descriptions")

    assert {:ok, decoded} = Row.from_json(row)
    assert decoded.label_descriptions == %{}
  end

  test "a finished label-only feature remains after 30 days" do
    recent = %{1 => closed(["feature:newsletter"], :completed, merged_at: ago(1))}
    stale = %{1 => closed(["feature:newsletter"], :completed, merged_at: ago(60), closed_at: ago(60))}

    assert [%{key: "newsletter", merged: 1, total: 1}] = FeatureBars.compute(parts(recent), @now)
    assert [%{key: "newsletter", label: "Newsletter", merged: 1, total: 1}] = FeatureBars.compute(parts(stale), @now)
  end

  test "configured goal order comes first, then features by their oldest ticket" do
    rows = %{1 => open(["feature:young"], 1), 2 => open(["feature:old"], 50), 3 => open(["feature:goal"], 5)}

    assert FeatureBars.compute(parts(rows, order: ["goal"]), @now) |> Enum.map(& &1.key) == ~w(goal old young)
  end

  test "unknown history yields no bars rather than zeros" do
    assert FeatureBars.compute(%{history: {:error, :unavailable}}, @now) == nil
    assert FeatureBars.grouped(%{history: {:error, :unavailable}}, @now) == nil
  end

  test "each epic row sums its features and keeps them in the epic's order" do
    rows = %{
      1 => closed(["feature:launch-api"], :completed, merged_at: ago(1), pr_number: 11),
      2 => open(["feature:launch-api"]),
      3 => closed(["feature:launch-ui"], :completed, merged_at: ago(2), pr_number: 12),
      4 => open(["feature:launch-ui"]),
      5 => open(["feature:later-data"]),
      6 => closed(["feature:later-ops"], :completed, merged_at: ago(3), pr_number: 13)
    }

    epics = [
      %{slug: "later", label: "Later", features: ["later-data", "later-ops"], created_at: ago(2)},
      %{slug: "launch", label: "Launch", features: ["launch-api", "launch-ui"], created_at: ago(9)}
    ]

    # Goal order lists launch-ui before launch-api. The epic's place is its first listed
    # feature's place (launch-api at index 1), while its own features keep the order its
    # record holds and later's first feature is not listed at all.
    %{bars: bars, epics: groups} = FeatureBars.grouped(parts(rows, epics: epics, order: ["launch-ui", "launch-api"]), @now)

    assert Enum.map(bars, & &1.key) == ~w(launch-ui launch-api later-ops later-data)

    assert Enum.map(groups, &Map.take(&1, [:key, :label, :merged, :total, :features])) == [
             %{key: "launch", label: "Launch", merged: 2, total: 4, features: ~w(launch-api launch-ui)},
             %{key: "later", label: "Later", merged: 1, total: 2, features: ~w(later-data later-ops)}
           ]
  end

  test "an epic sorts on its first listed feature, not on the earliest one goal order lists" do
    rows = %{
      1 => open(["feature:second-listed"]),
      2 => open(["feature:first-listed"]),
      3 => open(["feature:other"])
    }

    # "wide" lists second-listed first even though goal order puts first-listed at index 0;
    # "narrow" lists only first-listed. Reading "first listed feature" literally puts narrow
    # first, so a sort on the earliest goal position would order these the other way.
    epics = [
      %{slug: "wide", label: "Wide", features: ~w(second-listed first-listed), created_at: ago(1)},
      %{slug: "narrow", label: "Narrow", features: ~w(first-listed), created_at: ago(2)}
    ]

    %{epics: groups} = FeatureBars.grouped(parts(rows, epics: epics, order: ["first-listed", "second-listed"]), @now)
    assert Enum.map(groups, & &1.key) == ~w(narrow wide)

    # "other" is in no epic's list and in no goal order, so it sorts after both by creation.
    %{epics: later} = FeatureBars.grouped(parts(rows, epics: [%{slug: "loose", label: "Loose", features: ~w(other), created_at: ago(5)} | epics], order: []), @now)
    assert Enum.map(later, & &1.key) == ~w(loose narrow wide)
  end

  test "an epic counts a shared ticket once and leaves features no epic lists ungrouped" do
    rows = %{
      1 => closed(["feature:shared-a"], :completed, merged_at: ago(1), pr_number: 21),
      2 => open(["feature:shared-a", "feature:shared-b"]),
      3 => open(["feature:shared-b"]),
      4 => open(["feature:loose"])
    }

    epics = [%{slug: "both", label: "Both", features: ["shared-a", "shared-b"], created_at: ago(4)}]
    %{bars: bars, epics: [group]} = FeatureBars.grouped(parts(rows, epics: epics), @now)

    assert Map.new(bars, &{&1.key, {&1.merged, &1.total}}) == %{"shared-a" => {1, 2}, "shared-b" => {0, 2}, "loose" => {0, 1}}
    # shared-a and shared-b both hold ticket 2; the epic counts it once.
    assert Map.take(group, [:key, :merged, :total, :features]) == %{key: "both", merged: 1, total: 3, features: ~w(shared-a shared-b)}
    refute "loose" in group.features
  end

  test "epics with no ticketed features are not rows and an unreadable registry leaves grouping unknown" do
    rows = %{1 => open(["feature:known"])}
    epics = [%{slug: "empty", label: "Empty", features: ["missing"], created_at: ago(1)}]
    known = parts(rows, epics: epics)
    unreadable = %{known | features: {:error, %{state: :unavailable}}}

    assert %{epics: []} = FeatureBars.grouped(known, @now)
    assert %{bars: [%{key: "known"}], epics: nil} = FeatureBars.grouped(unreadable, @now)
  end

  test "epic rows without a goal-order feature sort by creation" do
    rows = %{1 => open(["feature:old"]), 2 => open(["feature:new"]), 3 => open(["feature:first"])}

    epics = [
      %{slug: "new", label: "New", features: ["new"], created_at: ago(1)},
      %{slug: "first", label: "First", features: ["first"], created_at: ago(30)},
      %{slug: "old", label: "Old", features: ["old"], created_at: ago(9)}
    ]

    assert %{epics: groups} = FeatureBars.grouped(parts(rows, epics: epics, order: ["first"]), @now)
    assert Enum.map(groups, & &1.key) == ~w(first old new)
  end

  test "the flat bars are the grouped bars" do
    rows = %{1 => open(["feature:a"]), 2 => open(["feature:a", "feature:b"])}
    epics = [%{slug: "both", label: "Both", features: ~w(a b), created_at: ago(1)}]
    parts = parts(rows, epics: epics)

    assert FeatureBars.compute(parts, @now) == FeatureBars.grouped(parts, @now).bars
  end
end
