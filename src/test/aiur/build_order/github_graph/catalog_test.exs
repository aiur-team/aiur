defmodule Aiur.BuildOrder.GitHubGraph.CatalogTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GitHubGraph.Queries
  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph
  alias Aiur.BuildOrder.ProviderResult
  alias AiurWeb.BuildOrder.Truncation

  test "a root beyond the selected read budget reports the truncated catalog count" do
    root = root(1)
    members = Enum.map(2..101, &catalog_member/1)
    node = Map.put(root, "subIssues", connection(members, 501, has_next?: true, cursor: "more"))
    assert {:ok, %{candidate: %{entries: [entry]}}} = GitHubGraph.fetch_catalog(base_opts(catalog_response([node], 1)))
    assert Truncation.notice(entry) =~ "100 of 501 members"
    assert {:error, %{error: :member_overflow}} = GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [], 501, has_next?: true, cursor: "more")))
  end

  test "keeps a malformed catalog root visible while valid siblings remain selectable" do
    valid = root(1)
    malformed = Map.put(root(2), "title", nil)

    assert {:ok, %ProviderResult{} = result} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([valid, malformed], 2)))

    assert result.status == :complete
    assert result.calls == 1
    assert result.pages == 1
    assert [%{identity: valid_identity}, invalid] = result.candidate.entries
    assert {:ok, _root} = Catalog.select(result.candidate, valid_identity)
    assert {:structurally_invalid, ^invalid} = Catalog.select(result.candidate, invalid.identity)
    assert :invalid_title in Enum.map(invalid.diagnostics, & &1.code)
  end

  # The members are shaped as the catalog query actually returns them —
  # lifecycle only, no `labels` connection — so this pins the metrics the
  # catalog can still claim once the per-member labels are gone (#1766).
  test "derives catalog progress from a root's direct GitHub members" do
    members = [catalog_member(2), catalog_member(3), catalog_member(4)]
    root = Map.put(root(1), "subIssues", connection(members, 3, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 3
    assert entry.progress == 67
    assert entry.progress_resolution == :resolved
    assert entry.progress_resolved_count == 3

    # Lane and phase are label-derived, and the catalog no longer buys the
    # labels. Unreported, not zero, and not a dropped progress figure.
    assert is_nil(entry.epic_count)
    assert is_nil(entry.phase_count)
  end

  # The other half of the contract above: when a read *does* buy the per-member
  # labels, the same normalizer resolves both counts to real integers. This is
  # what makes the catalog page show numbers instead of "Unresolved".
  test "resolves catalog epic and wave counts when the read buys per-member labels" do
    members = [
      labelled_catalog_member(2, ["phase:1", "build-lane:runtime"]),
      labelled_catalog_member(3, ["phase:1", "build-lane:ui"]),
      labelled_catalog_member(4, ["phase:2", "build-lane:ui"])
    ]

    root = Map.put(root(1), "subIssues", connection(members, 3, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1), member_labels: true))

    assert entry.member_count == 3
    assert entry.epic_count == 2
    assert entry.phase_count == 2

    # Progress is lifecycle-derived and must be untouched by the extra labels.
    assert entry.progress_resolution == :resolved
  end

  # Cost guard for #1766. A nested `labels` connection under the catalog's
  # `subIssues` bills once per *parent*, so it costs 25 roots x 100 sub-issues =
  # 2,500 request-units — measured at 26 GraphQL points per page against a
  # 5,000-points/hour budget, versus 1 point without it. It is opt-in precisely
  # so the recurring catalog poll never pays it. If this test starts failing
  # because the default variant grew a member `labels` selection, the fix is not
  # to update the assertion.
  test "keeps per-member labels off the default catalog query and on the opt-in variant" do
    default = Queries.catalog()
    labelled = Queries.catalog(member_labels?: true)

    assert default == Queries.catalog(member_labels?: false)
    assert default == Queries.catalog([])

    assert catalog_sub_issues_selection(default) =~ "state stateReason"
    refute catalog_sub_issues_selection(default) =~ "labels"

    assert catalog_sub_issues_selection(labelled) =~ "labels(first: 100)"
    assert catalog_sub_issues_selection(labelled) =~ "nodes { name }"

    # Only the member selection differs; the labelled variant is otherwise the
    # same query, including the root-level `labels` the catalog has always had.
    assert String.replace(labelled, catalog_sub_issues_selection(labelled), catalog_sub_issues_selection(default)) ==
             default
  end

  test "marks catalog progress unresolved when no member lifecycle can be resolved" do
    root = root(1)

    unresolved_members = [
      catalog_member(2) |> Map.put("state", "UNRECOGNIZED"),
      catalog_member(3) |> Map.delete("state")
    ]

    root = Map.put(root, "subIssues", connection(unresolved_members, 2, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 2
    assert is_nil(entry.epic_count)
    assert is_nil(entry.phase_count)
    assert is_nil(entry.progress)
    assert entry.progress_resolution == :unresolved
    assert entry.progress_resolved_count == 0
  end

  test "reports catalog progress over the members whose lifecycle resolved" do
    root = root(1)

    members = [
      catalog_member(2),
      catalog_member(3) |> Map.put("state", "UNRECOGNIZED")
    ]

    root = Map.put(root, "subIssues", connection(members, 2, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.progress == 100
    assert entry.progress_resolution == :partial
    assert entry.progress_resolved_count == 1
    assert entry.member_count == 2
  end

  test "keeps the member total but marks an incomplete catalog connection unresolved" do
    root = root(1)
    root = Map.put(root, "subIssues", connection([catalog_member(2)], 101, has_next?: true, cursor: "next-page"))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 101
    assert is_nil(entry.progress)
    assert entry.progress_resolution == :unresolved
    assert entry.progress_resolved_count == 0
  end

  test "makes no member claim when a catalog connection carries no readable total" do
    root =
      Map.put(root(1), "subIssues", %{
        "nodes" => [catalog_member(2)],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert is_nil(entry.member_count)
    assert is_nil(entry.progress)
    assert entry.progress_resolution == :unresolved
  end

  test "keeps a catalog root missing its required parent key visible but invalid" do
    valid = root(1)
    missing_parent = Map.delete(root(2), "parent")

    assert {:ok, %{candidate: catalog}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([valid, missing_parent], 2)))

    [valid_entry, invalid_entry] = catalog.entries
    assert {:ok, _root} = Catalog.select(catalog, valid_entry.identity)
    assert {:structurally_invalid, ^invalid_entry} = Catalog.select(catalog, invalid_entry.identity)
    assert :invalid_identity in Enum.map(invalid_entry.diagnostics, & &1.code)
  end

  test "keeps an unlabeled catalog root visible but structurally invalid" do
    valid = root(1)
    unlabeled = root(2) |> Map.put("labels", labels([]))

    assert {:ok, %{candidate: catalog}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([valid, unlabeled], 2)))

    [valid_entry, unlabeled_entry] = catalog.entries
    assert {:ok, _root} = Catalog.select(catalog, valid_entry.identity)
    assert {:structurally_invalid, ^unlabeled_entry} = Catalog.select(catalog, unlabeled_entry.identity)
    assert :missing_root_label in Enum.map(unlabeled_entry.diagnostics, & &1.code)
  end

  test "keeps a catalog root with an incomplete label connection visible" do
    valid = root(1)
    malformed = root(2) |> Map.put("labels", connection([], 1, []))

    assert {:ok, %{candidate: catalog}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([valid, malformed], 2)))

    [valid_entry, invalid_entry] = catalog.entries
    assert {:ok, _root} = Catalog.select(catalog, valid_entry.identity)
    assert {:structurally_invalid, ^invalid_entry} = Catalog.select(catalog, invalid_entry.identity)
    assert :incomplete_labels in Enum.map(invalid_entry.diagnostics, & &1.code)
  end

  test "accepts the exact default root bound without per-root reads" do
    roots = Enum.map(1..100, &root/1)

    responses =
      roots
      |> Enum.chunk_every(25)
      |> Enum.with_index()
      |> Enum.map(fn {page, index} ->
        catalog_response(page, 100, has_next?: index < 3, cursor: if(index < 3, do: "root-page-#{index + 2}"))
      end)

    request_fun = queued_responses(responses)

    assert {:ok, result} = GitHubGraph.fetch_catalog(base_opts(request_fun))

    assert length(result.candidate.entries) == 100
    assert result.calls == 4
    assert result.pages == 4
    assert Enum.map(drain_requests(), &Map.fetch!(&1, "pageSize")) == [25, 25, 25, 25]
  end

  test "fails closed on catalog overflow, cursor inconsistency, page two errors, and invalid bounds" do
    overflow = queued_responses([catalog_response(Enum.map(1..100, &root/1), 101, has_next?: true, cursor: "next")])

    assert {:error, %{error: :catalog_overflow, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(overflow, root_limit: 100, page_budget: 4, call_budget: 4))

    malformed_cursor = queued_responses([catalog_response([root(1)], 2, has_next?: true, cursor: nil)])

    assert {:error, %{error: :pagination_mismatch, calls: 1, pages: 1}} =
             GitHubGraph.fetch_catalog(base_opts(malformed_cursor, page_budget: 2, call_budget: 2))

    page_two_error =
      queued_responses([
        catalog_response([root(1)], 2, has_next?: true, cursor: "page-two"),
        graphql_error()
      ])

    assert {:error, %{error: :graphql_partial, calls: 2, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(page_two_error, page_budget: 2, call_budget: 2))

    invalid_bounds = fn _request -> flunk("invalid configuration must not reach GitHub") end

    assert {:error, %{error: :invalid_planning_bounds, calls: 0, pages: 0}} =
             GitHubGraph.fetch_catalog(base_opts(invalid_bounds, root_limit: 0))
  end

  test "rejects a continuation after the reported catalog or member total is already complete" do
    root = root(1)

    catalog_pages = [
      catalog_response([root], 1, has_next?: true, cursor: "catalog-page-2"),
      catalog_response([], 1)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses(catalog_pages), page_budget: 2, call_budget: 2))

    member_pages = [
      selected_response(root, [member(2, root)], 1, has_next?: true, cursor: "member-page-2"),
      selected_response(root, [], 1)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(queued_responses(member_pages), page_budget: 2, call_budget: 2)
             )
  end

  test "treats a continuation at the configured catalog or member bound as overflow" do
    root = root(1)

    catalog =
      catalog_response(Enum.map(1..100, &root/1), 100, has_next?: true, cursor: "catalog-page-2")

    assert {:error, %{error: :catalog_overflow, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(catalog))

    members = Enum.map(2..101, &member(&1, root))
    selected = selected_response(root, members, 100, has_next?: true, cursor: "member-page-2")

    assert {:error, %{error: :member_overflow, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected))
  end

  test "fails closed when a catalog page changes the reported total" do
    responses = [
      catalog_response([root(1)], 3, has_next?: true, cursor: "root-page-2"),
      catalog_response([root(2)], 2)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 2, pages: 2, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses(responses), page_budget: 2, call_budget: 2))
  end
end
