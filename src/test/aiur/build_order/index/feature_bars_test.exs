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
    registry = %{features: Map.new(Keyword.get(opts, :registry, []), fn {slug, label} -> {slug, %{label: label}} end), owners: Keyword.get(opts, :owners, %{})}
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
  end
end
