defmodule Aiur.LaneTest do
  @moduledoc """
  A ticket's lanes are the technical columns its work belongs to. They come from
  `lane:`, `area:` and `build-lane:` labels and from the label matchers of a
  configured general epic, so an existing install needs no GitHub relabel.
  """
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Lane

  defp issue(labels), do: %Issue{identifier: "1", title: "t", description: "", labels: labels}

  defp settings(general_epics), do: %{build_order: %{general_epics: general_epics}}

  test "reads lane slugs from all three label prefixes" do
    assert Lane.resolve(issue(["lane:art", "area:ui", "build-lane:docs"]), settings([])) == ["art", "ui", "docs"]
  end

  test "keeps prefix order and deduplicates" do
    labels = ["build-lane:docs", "area:docs", "lane:art", "area:art"]
    assert Lane.resolve(issue(labels), settings([])) == ["art", "docs"]
  end

  test "adds general-epic keys whose label matchers hit" do
    epics = [
      %{key: "art", labels: ["area:art"]},
      %{key: "infra", labels: ["area:infra"]}
    ]

    assert Lane.resolve(issue(["area:infra"]), settings(epics)) == ["infra"]
  end

  test "puts prefix labels before general-epic keys and deduplicates across both" do
    epics = [%{key: "art", labels: ["art"]}]
    assert Lane.resolve(issue(["area:art"]), settings(epics)) == ["art"]
    assert Lane.resolve(issue(["area:ui", "art"]), settings(epics)) == ["ui", "art"]
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
end
