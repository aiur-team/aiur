defmodule Aiur.LaneTest do
  @moduledoc """
  A ticket's lanes are the technical columns its work belongs to. They come from
  `lane:`, `area:` and `build-lane:` labels and from the label matchers of a
  configured lane (`build_order.lanes`), so an existing install needs no GitHub
  relabel.
  """
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Lane

  defp issue(labels), do: %Issue{identifier: "1", title: "t", description: "", labels: labels}

  defp settings(lanes), do: %{build_order: %{lanes: lanes}}

  test "reads lane slugs from all three label prefixes" do
    assert Lane.resolve(issue(["lane:art", "area:ui", "build-lane:docs"]), settings([])) == ["art", "ui", "docs"]
  end

  test "keeps prefix order and deduplicates" do
    labels = ["build-lane:docs", "area:docs", "lane:art", "area:art"]
    assert Lane.resolve(issue(labels), settings([])) == ["art", "docs"]
  end

  test "adds configured lane keys whose label matchers hit" do
    lanes = [
      %{key: "art", labels: ["area:art"]},
      %{key: "infra", labels: ["area:infra"]}
    ]

    assert Lane.resolve(issue(["area:infra"]), settings(lanes)) == ["infra"]
  end

  test "an area:frontend ticket resolves to the configured frontend lane" do
    lanes = [%{key: "frontend", label: "Frontend", labels: ["area:frontend", "ui"]}]

    assert Lane.resolve(issue(["area:frontend"]), settings(lanes)) == ["frontend"]
    assert Lane.resolve(issue(["ui"]), settings(lanes)) == ["frontend"]
    assert Lane.resolve(issue(["area:backend"]), settings(lanes)) == ["backend"]
  end

  test "a lane's own key matches a prefix label of the same slug without a matcher" do
    lanes = [%{key: "frontend", labels: []}]

    assert Lane.resolve(issue(["build-lane:frontend"]), settings(lanes)) == ["frontend"]
  end

  test "puts prefix labels before configured lane keys and deduplicates across both" do
    lanes = [%{key: "art", labels: ["art"]}]
    assert Lane.resolve(issue(["area:art"]), settings(lanes)) == ["art"]
    assert Lane.resolve(issue(["area:ui", "art"]), settings(lanes)) == ["ui", "art"]
  end

  test "normalizes label case and whitespace" do
    assert Lane.resolve(issue(["  AREA:Art  "]), settings([])) == ["art"]
  end

  test "ignores a suffix that is not a lane slug" do
    assert Lane.resolve(issue(["area:", "area:Not A Lane", "lane:art"]), settings([])) == ["art"]
  end

  test "ignores non-binary labels" do
    assert Lane.resolve(issue([:area_art, "area:art"]), settings([])) == ["art"]
  end

  test "no labels and no configured matchers resolves to no lanes" do
    assert Lane.resolve(issue([]), settings([])) == []
  end

  test "an unavailable settings value means no configured lanes, not a crash" do
    assert Lane.resolve(issue(["area:art"]), nil) == ["art"]
    assert Lane.resolve(nil, nil) == []
    assert Lane.resolve(%{}, %{build_order: :unavailable}) == []
  end

  test "reads configured lanes from an {:ok, settings} read and from the bare struct" do
    lanes = [%{key: "frontend", labels: ["area:frontend"]}]

    assert Lane.configured({:ok, settings(lanes)}) == lanes
    assert Lane.configured(settings(lanes)) == lanes
    assert Lane.configured({:error, :unavailable}) == []
    assert Lane.resolve(issue(["area:frontend"]), {:ok, settings(lanes)}) == ["frontend"]
  end

  test "label_match names the label that placed a ticket in a lane" do
    lane = %{key: "frontend", labels: ["ui"]}

    assert Lane.label_match(lane, issue(["ui"])) == "ui"
    assert Lane.label_match(lane, issue(["lane:frontend"])) == "lane:frontend"
    assert Lane.label_match(lane, issue(["area:backend"])) == nil
    assert Lane.matches?(lane, issue(["  AREA:backend  "])) == false
  end

  test "label_lanes lists only the prefix labels' slugs" do
    assert Lane.label_lanes(issue(["area:ui", "bug", "lane:art"])) == ["art", "ui"]
    assert Lane.label_lanes(nil) == []
  end
end
