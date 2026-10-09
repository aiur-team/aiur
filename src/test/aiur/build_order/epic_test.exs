defmodule Aiur.BuildOrder.EpicTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Aiur.BuildOrder.Epic
  alias Aiur.BuildOrder.Epic.Resolution
  alias Aiur.Config.Schema.GeneralEpic

  @general [
    %GeneralEpic{key: "bugs", labels: ["bug"]},
    %GeneralEpic{key: "design", labels: ["design"]},
    %GeneralEpic{key: "infra", labels: ["refactor", "chore"]},
    %GeneralEpic{key: "docs", labels: ["documentation"]}
  ]
  @features %{"pag" => ["f-pag-api", "f-pag-ui"], "docs-site" => ["f-docs"], "empty" => []}
  @context %{general: @general, features: @features}
  @owner %{feature: "pag", epic: "f-pag-ui", joined_at: 123}

  test "V-1 empty and unmatched labels resolve to default Unsorted" do
    assert resolve(%{labels: []}) == result("unsorted", "default")
    assert Epic.resolve(%{labels: ["bug"]}, %{@context | general: []}) == result("unsorted", "default")
    assert resolve(%{labels: ["build-lane:home", "bugfix"]}) == result("unsorted", "default")
  end

  test "V-2 config order decides EC-21, regardless of ticket label order" do
    for labels <- [["refactor", "bug"], ["bug", "refactor"]] do
      assert resolve(%{labels: labels}) == result("bugs", "label:bug")
      assert Epic.resolve(%{labels: labels}, %{@context | general: Enum.reverse(@general)}) == result("infra", "label:refactor")
    end
  end

  test "V-3 unavailable labels are unknown, not a default" do
    assert resolve(%{labels: :unknown}) == result("unsorted", "unknown", [], [:labels])
    assert resolve(%{}) == result("unsorted", "unknown", [], [:labels])
  end

  test "V-4 owning feature precedes labels" do
    assert resolve(%{owning_feature: %{feature: "docs-site", epic: "f-docs"}, labels: ["bug"]}) == result("f-docs", "feature")
  end

  test "V-5 owner epic is preserved or repaired to first feature epic" do
    assert resolve(%{owning_feature: @owner}) == result("f-pag-ui", "feature")
    assert resolve(%{owning_feature: %{@owner | epic: "f-gone"}}) == result("f-pag-api", "feature", [:owner_epic_missing])
  end

  test "V-6 feature precedes override and reports it ignored" do
    assert resolve(%{owning_feature: @owner, override: %{epic: "bugs", actor: "agent-1"}}) == result("f-pag-ui", "feature", [:override_outside_feature])
  end

  test "V-7 general override precedes labels, preserving actor" do
    assert resolve(%{override: %{epic: "infra", actor: "agent-1", confirmed: false}, labels: ["bug"]}) == result("infra", "override:agent-1")
  end

  test "V-8 removed override falls through with a reason" do
    assert resolve(%{override: %{epic: "ops", actor: "agent-1"}, labels: ["bug"]}) == result("bugs", "label:bug", [:override_unknown_epic])
  end

  test "V-9 feature and Unsorted overrides are rejected" do
    for key <- ["f-pag-ui", "unsorted"] do
      assert resolve(%{override: %{epic: key, actor: "agent-1"}, labels: ["bug"]}) == result("bugs", "label:bug", [:override_unknown_epic])
    end
  end

  test "V-10 unknown owner or registry preserves feature gap" do
    for {owner, features} <- [{:unknown, @features}, {@owner, :unknown}, {:none, :unknown}] do
      context = %{@context | features: features}
      assert Epic.resolve(%{owning_feature: owner, labels: ["documentation"]}, context) == result("docs", "label:documentation", [], [:feature])
      assert Epic.resolve(%{owning_feature: owner, labels: []}, context) == result("unsorted", "unknown", [], [:feature])
    end
  end

  test "V-11 dangling and empty features fall through with reasons" do
    for {slug, reason} <- [{"gone", :feature_missing}, {"empty", :feature_without_epics}] do
      assert resolve(%{owning_feature: %{feature: slug, epic: "old"}, labels: ["bug"]}) == result("bugs", "label:bug", [reason])
    end
  end

  test "V-12 unavailable override is a gap even when labels decide" do
    assert resolve(%{override: :unknown, labels: []}) == result("unsorted", "unknown", [], [:override])
    assert resolve(%{override: :unknown, labels: ["bug"]}) == result("bugs", "label:bug", [], [:override])
  end

  test "V-13 ticket labels normalize and discard invalid entries" do
    assert resolve(%{labels: [" Bug ", 42, nil, "", <<255>>, String.duplicate("x", 257)]}) == result("bugs", "label:bug")
    assert resolve(%{labels: [42, nil, "", <<255>>, String.duplicate("x", 257)]}) == result("unsorted", "default")
  end

  test "V-14 configured matcher order decides source within an epic" do
    assert resolve(%{labels: ["chore", "refactor"]}) == result("infra", "label:refactor")
    context = %{@context | general: [%{key: "infra", labels: ["chore", "refactor"]}]}
    assert Epic.resolve(%{labels: ["refactor", "chore"]}, context) == result("infra", "label:chore")
  end

  test "V-15 Unsorted descriptor matches the adopted design" do
    assert Epic.unsorted() == %{key: "unsorted", label: "Unsorted", hue: 0, icon: "unsorted", unsorted: true}
  end

  test "V-16 incomplete labels create a gap only without a match" do
    for complete <- [false, :unknown] do
      assert resolve(%{labels: ["agent:done"], labels_complete: complete}) == result("unsorted", "unknown", [], [:labels])
      assert resolve(%{labels: ["bug"], labels_complete: complete}) == result("bugs", "label:bug")
    end
  end

  property "P-1 key belongs to general, Unsorted, or the owning feature" do
    check all(ticket <- ticket_generator()) do
      owned_epics =
        case ticket.owning_feature do
          %{feature: slug} -> Map.get(@features, slug, [])
          _ -> []
        end

      assert resolve(ticket).key in (["unsorted" | Enum.map(@general, & &1.key)] ++ owned_epics)
    end
  end

  property "P-2 reordered and duplicated labels preserve the full decision" do
    check all(ticket <- ticket_generator()) do
      reordered =
        case ticket.labels do
          :unknown -> :unknown
          labels -> Enum.reverse(labels) ++ labels
        end

      assert resolve(%{ticket | labels: reordered}) == resolve(ticket)
    end
  end

  property "P-3 unavailable inputs never claim default" do
    check all(ticket <- ticket_generator()) do
      resolution = resolve(%{ticket | owning_feature: :unknown})
      assert :feature in resolution.gaps
      assert resolution.source != "default"
    end
  end

  property "P-4 known owning feature always controls the column" do
    check all(ticket <- ticket_generator(), epic <- member_of(["f-pag-api", "f-pag-ui", "stale"])) do
      resolution = resolve(%{ticket | owning_feature: %{@owner | epic: epic}})
      assert resolution.key in @features["pag"]
      assert resolution.source == "feature"
    end
  end

  defp ticket_generator do
    gen all(
          labels <- one_of([constant(:unknown), list_of(member_of(~w(bug design refactor chore documentation noise)), max_length: 12)]),
          owner <- member_of([:none, :unknown, @owner, %{@owner | epic: "stale"}, %{@owner | feature: "gone"}]),
          override <- member_of([:none, :unknown | Enum.map(~w(bugs infra removed unsorted f-pag-ui), &%{epic: &1, actor: "tester"})]),
          complete <- member_of([true, false, :unknown])
        ) do
      %{labels: labels, owning_feature: owner, override: override, labels_complete: complete}
    end
  end

  defp resolve(ticket), do: Epic.resolve(ticket, @context)
  defp result(key, source, ignored \\ [], gaps \\ []), do: %Resolution{key: key, source: source, ignored: ignored, gaps: gaps}
end
