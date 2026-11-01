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
      1 => closed(["feature:mp-e2"], :completed, merged_at: ago(1), pr_number: 50, label_descriptions: %{"feature:mp-e2" => "Feature collection: MP-E2 Commands"}),
      2 => closed(["feature:mp-e2"], :completed, merged_at: :none, pr_number: :none),
      3 => closed(["feature:mp-e2"], :completed, merged_at: :none, pr_number: 51),
      4 => closed(["feature:mp-e2"], :not_planned),
      5 => open(["feature:mp-e2", "area:ui"]),
      6 => open(["feature:Bad Slug"])
    }

    assert FeatureBars.compute(parts(rows), @now) == [%{key: "mp-e2", label: "MP-E2 Commands", merged: 2, total: 3}]
    history_row = rows[1]
    assert {:ok, "mp-e2"} = history_row.labels |> hd() |> LabelRules.parse()
  end

  test "registry members and labels join under one slug; registry label wins and empty features are hidden" do
    rows = %{1 => closed([], :completed, merged_at: ago(1), pr_number: 9), 2 => open(["feature:bo-7"])}
    parts = parts(rows, registry: [{"bo-7", "BO: Seven"}, {"bo-8", "BO: Empty"}], owners: %{1 => %{feature: "bo-7"}})

    assert FeatureBars.compute(parts, @now) == [%{key: "bo-7", label: "BO: Seven", merged: 1, total: 2}]
  end

  test "Build Order root labels show the distinguishing suffix" do
    rows = %{1 => open(["feature:bo-7"])}
    parts = parts(rows, registry: [{"bo-7", "BO: Platform program 2026-10 — MP-E1 build queue (wave 0)"}])

    assert [%{label: "MP-E1 build queue"}] = FeatureBars.compute(parts, @now)
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
    assert [%{key: "newsletter", label: "newsletter", merged: 1, total: 1}] = FeatureBars.compute(parts(stale), @now)
  end

  test "configured goal order comes first, then features by their oldest ticket" do
    rows = %{1 => open(["feature:young"], 1), 2 => open(["feature:old"], 50), 3 => open(["feature:goal"], 5)}

    assert FeatureBars.compute(parts(rows, order: ["goal"]), @now) |> Enum.map(& &1.key) == ~w(goal old young)
  end

  test "unknown history yields no bars rather than zeros" do
    assert FeatureBars.compute(%{history: {:error, :unavailable}}, @now) == nil
  end
end
