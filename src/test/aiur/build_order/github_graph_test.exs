defmodule Aiur.BuildOrder.GitHubGraphTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.Catalog, BuildOrder.ProviderResult, BuildOrder.SelectedRoot, GitHub.Client, TrackerIdentity}
  alias Aiur.BuildOrder.GitHubGraph, as: ProductionGraph
  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph

  @repository {"owner", "repo"}

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

  test "derives catalog metrics from a root's direct GitHub members" do
    root = root(1)

    members = [
      member(2, root, labels: ["phase:1", "build-lane:runtime"]),
      member(3, root, labels: ["phase:2", "build-lane:runtime"]),
      member(4, root, labels: ["phase:2", "build-lane:dashboard-ui"])
    ]

    root = Map.put(root, "subIssues", connection(members, 3, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 3
    assert entry.epic_count == 2
    assert entry.phase_count == 2
    assert entry.progress == 67
    assert entry.progress_resolution == :resolved
    assert entry.progress_resolved_count == 3
  end

  test "marks catalog progress unresolved when no member lifecycle can be resolved" do
    root = root(1)

    unresolved_members = [
      member(2, root) |> Map.put("state", "UNRECOGNIZED"),
      member(3, root) |> Map.delete("state")
    ]

    root = Map.put(root, "subIssues", connection(unresolved_members, 2, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 2
    assert entry.epic_count == 1
    assert entry.phase_count == 1
    assert is_nil(entry.progress)
    assert entry.progress_resolution == :unresolved
    assert entry.progress_resolved_count == 0
  end

  test "leaves catalog counts unresolved when member labels are truncated" do
    root = root(1)

    member =
      member(2, root)
      |> Map.put("labels", connection(Enum.map(1..20, &%{"name" => "label-#{&1}"}), 21, has_next?: true, cursor: "more-labels"))

    root = Map.put(root, "subIssues", connection([member], 1, []))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 1
    assert is_nil(entry.epic_count)
    assert is_nil(entry.phase_count)
    assert entry.progress == 100
    assert entry.progress_resolution == :resolved
    assert entry.progress_resolved_count == 1
  end

  test "reports catalog progress over the members whose lifecycle resolved" do
    root = root(1)

    members = [
      member(2, root),
      member(3, root) |> Map.put("state", "UNRECOGNIZED")
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
    members = [member(2, root)]
    root = Map.put(root, "subIssues", connection(members, 101, has_next?: true, cursor: "next-page"))

    assert {:ok, %{candidate: %{entries: [entry]}}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root], 1)))

    assert entry.member_count == 101
    assert is_nil(entry.progress)
    assert entry.progress_resolution == :unresolved
    assert entry.progress_resolved_count == 0
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

  test "classifies an invalid requested root without provider I/O" do
    root = root(1)

    for invalid_root <- [
          %{identity(root) | repository: "other-repository"},
          %{identity(root) | identifier: "0"}
        ] do
      request_fun = fn _request -> flunk("invalid requested roots must not reach GitHub") end

      assert {:error, %{error: :invalid_requested_root, calls: 0, pages: 0, candidate: nil, diagnostics: diagnostics}} =
               GitHubGraph.fetch_selected_root(invalid_root, base_opts(request_fun))

      assert :invalid_requested_root in Enum.map(diagnostics, & &1.code)
    end
  end

  test "detects finite page and call budget exhaustion without returning a partial catalog" do
    first_page = catalog_response([root(1)], 2, has_next?: true, cursor: "page-two")

    assert {:error, %{error: :page_budget_exhausted, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses([first_page]), page_budget: 1, call_budget: 2))

    assert {:error, %{error: :call_budget_exhausted, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses([first_page]), page_budget: 2, call_budget: 1))
  end

  test "classifies a malformed GraphQL connection as a schema failure" do
    malformed = graphql_response(%{"data" => %{"repository" => %{"issues" => %{"nodes" => []}}}})

    assert {:error, %{error: :schema, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(malformed))
  end

  test "rejects omitted terminal PageInfo cursors for outer and inner connections" do
    root = root(1)

    catalog = without_terminal_cursor(catalog_response([root], 1), ["data", "repository", "issues"])

    assert {:error, %{error: :schema, calls: 1, pages: 1, candidate: nil, diagnostics: catalog_diagnostics}} =
             GitHubGraph.fetch_catalog(base_opts(catalog))

    assert :provider_schema in Enum.map(catalog_diagnostics, & &1.code)

    selected = without_terminal_cursor(selected_response(root, [], 0), ["data", "repository", "issue", "subIssues"])

    assert {:error, %{error: :schema, calls: 1, pages: 1, candidate: nil, diagnostics: selected_diagnostics}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected))

    assert :provider_schema in Enum.map(selected_diagnostics, & &1.code)

    malformed_root = Map.update!(root, "labels", &without_terminal_cursor/1)

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(malformed_root, [], 0)))

    assert :invalid_label_connection in Enum.map(selected.root.diagnostics, & &1.code)

    for {key, count_key} <- [{"blockedBy", :blocked_by}, {"blocking", :blocking}] do
      child = Map.put(member(2, root), key, dependency_connection([endpoint(9)]) |> without_terminal_cursor())

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

      [selected_member] = selected.members
      assert selected_member.connection_counts[count_key] == 1
      assert :connection_overflow in Enum.map(selected_member.diagnostics, & &1.code)
    end
  end

  test "classifies malformed HTTP-200 envelopes as provider schema failures" do
    root = root(1)

    for response <- [
          %{status: 200, body: "unexpected scalar"},
          %{status: 200, body: []},
          %{status: 200, body: nil},
          %{status: 200},
          %{status: 200, body: %{"errors" => "unexpected scalar"}},
          %{status: 200, body: %{"data" => %{"repository" => %{}}, "errors" => "unexpected scalar"}},
          %{status: 200, body: %{"errors" => nil}},
          %{status: 200, body: %{"errors" => %{}}},
          %{status: 200, body: %{"errors" => ["unexpected scalar"]}},
          %{status: 200, body: %{"errors" => []}}
        ] do
      request_fun = fn _request -> {:ok, response} end

      assert {:error, %{error: :schema, calls: 1, pages: 0, candidate: nil, diagnostics: catalog_diagnostics}} =
               GitHubGraph.fetch_catalog(base_opts(request_fun))

      assert :provider_schema in Enum.map(catalog_diagnostics, & &1.code)

      assert {:error, %{error: :schema, calls: 1, pages: 0, candidate: nil, diagnostics: selected_diagnostics}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(request_fun))

      assert :provider_schema in Enum.map(selected_diagnostics, & &1.code)
    end
  end

  test "retains rate-limit observations for malformed HTTP-200 envelopes" do
    response = %{
      status: 200,
      headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1783987200"}],
      body: "unexpected scalar"
    }

    assert {:error, %{error: :schema, rate_limit: %{remaining: 0, reset_at: "2026-07-14T00:00:00Z"}}} =
             GitHubGraph.fetch_catalog(base_opts(fn _request -> {:ok, response} end))
  end

  test "fails closed on malformed HTTP-200 headers" do
    root = root(1)

    for headers <- [nil, "malformed"] do
      response = %{status: 200, headers: headers, body: "unexpected scalar"}
      request_fun = fn _request -> {:ok, response} end

      assert {:error, %{error: :schema, calls: 1, pages: 0, candidate: nil, diagnostics: catalog_diagnostics}} =
               GitHubGraph.fetch_catalog(base_opts(request_fun))

      assert :provider_schema in Enum.map(catalog_diagnostics, & &1.code)

      assert {:error, %{error: :schema, calls: 1, pages: 0, candidate: nil, diagnostics: selected_diagnostics}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(request_fun))

      assert :provider_schema in Enum.map(selected_diagnostics, & &1.code)
    end
  end

  test "fails closed on malformed nested GraphQL data for catalog and selected roots" do
    root = root(1)

    for body <- [
          %{},
          %{"data" => nil},
          %{"data" => []},
          %{"data" => %{"repository" => []}},
          %{"data" => %{"repository" => "invalid"}}
        ] do
      response = graphql_response(body)

      assert {:error, %{error: :schema, calls: 1, pages: 1, candidate: nil, diagnostics: catalog_diagnostics}} =
               GitHubGraph.fetch_catalog(base_opts(response))

      assert :provider_schema in Enum.map(catalog_diagnostics, & &1.code)

      assert {:error, %{error: :schema, calls: 1, pages: 1, candidate: nil, diagnostics: selected_diagnostics}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(response))

      assert :provider_schema in Enum.map(selected_diagnostics, & &1.code)
    end
  end

  test "fails closed on nullable GraphQL nodes in every planning connection" do
    assert {:error, %{error: :schema, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([nil], 1)))

    root = root(1)

    assert {:error, %{error: :schema, candidate: nil}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [nil], 1)))

    root_with_null_label = Map.put(root, "labels", connection([nil], 1, []))

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root_with_null_label, [], 0))
             )

    assert :invalid_label_connection in Enum.map(selected.root.diagnostics, & &1.code)

    child_with_null_dependency = member(2, root) |> Map.put("blockedBy", connection([nil], 1, []))

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [child_with_null_dependency], 1))
             )

    [selected_member] = selected.members
    assert :connection_overflow in Enum.map(selected_member.diagnostics, & &1.code)
  end

  test "fetches a complete direct-member graph at the exact member bound without N plus one calls" do
    root = root(1)
    members = Enum.map(2..101, &member(&1, root))

    responses =
      members
      |> Enum.chunk_every(25)
      |> Enum.with_index()
      |> Enum.map(fn {page, index} ->
        selected_response(
          root,
          page,
          100,
          has_next?: index < 3,
          cursor: if(index < 3, do: "member-page-#{index + 2}")
        )
      end)

    assert {:ok, result} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(queued_responses(responses), page_budget: 4, call_budget: 4)
             )

    assert result.status == :complete
    assert result.calls == 4
    assert result.pages == 4
    assert length(result.candidate.members) == 100
    assert Enum.all?(result.candidate.members, &(&1.parent_identity == result.candidate.root.identity))
    assert Enum.map(drain_requests(), &Map.fetch!(&1, "pageSize")) == [25, 25, 25, 25]
  end

  test "anchors selected-root reads to a joinable requested canonical identity" do
    root = root(1)
    request = fn _request -> flunk("invalid selected-root input must not reach GitHub") end

    assert {:error, %{error: :invalid_requested_root, calls: 0, diagnostics: diagnostics}} =
             GitHubGraph.fetch_selected_root(1, base_opts(request))

    assert :invalid_requested_root in Enum.map(diagnostics, & &1.code)

    for returned_root <- [
          Map.put(root, "id", "RETURNED_OTHER_NODE"),
          root(2),
          issue_node(1, "other", "repo") |> Map.put("labels", labels(["build-order"]))
        ] do
      assert {:error, %{error: :schema, candidate: nil, calls: 1}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(returned_root, [], 0))
               )
    end
  end

  test "rejects selected-root field drift across GraphQL pages" do
    root = root(1)

    responses = [
      selected_response(root, [member(2, root)], 2, has_next?: true, cursor: "member-page-2"),
      selected_response(Map.put(root, "title", "Changed title"), [member(3, root)], 2)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 2, pages: 2, candidate: nil}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(queued_responses(responses), page_budget: 2, call_budget: 2)
             )
  end

  test "normalizes both dependency source connections to blocker-to-blocked and preserves an external endpoint" do
    root = root(1)
    external = endpoint(44, "other", "repo")
    internal = endpoint(1)

    child =
      member(2, root,
        blocked_by: [external],
        blocking: [internal]
      )

    assert {:ok, result} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    assert result.calls == 1
    [member] = result.candidate.members
    [upstream, downstream] = member.dependencies

    assert %{kind: :external, direction: :blocker_to_blocked, source_connection: :blocked_by} = upstream
    assert upstream.identity.owner == "other"
    assert upstream.identity.repository == "repo"
    assert upstream.blocker_identity == upstream.identity
    assert upstream.blocked_identity == member.identity
    assert :external_dependency in Enum.map(upstream.diagnostics, & &1.code)

    assert %{kind: :native, direction: :blocker_to_blocked, source_connection: :blocking} = downstream
    assert downstream.blocker_identity == member.identity
    assert downstream.blocked_identity == result.candidate.root.identity
    assert member.connection_counts == %{blocked_by: 1, blocking: 1}
    assert length(drain_requests()) == 1
  end

  test "rejects malformed selected graphs without discarding their failure evidence" do
    root = root(1)
    duplicate = member(2, root)

    assert {:error, %{error: :duplicate_identity, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [duplicate, duplicate], 2))
             )

    assert length(selected.members) == 2
    assert SelectedRoot.status(selected) == :structurally_invalid

    missing_endpoint = member(3, root, blocked_by: [%{}])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [missing_endpoint], 1)))

    [member] = selected.members
    assert :invalid_dependency in Enum.map(member.diagnostics, & &1.code)

    explicit_null_parent = Map.put(member(4, root), "parent", nil)

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [explicit_null_parent], 1))
             )

    diagnostic_codes =
      Enum.flat_map(selected.members, fn member ->
        Enum.map(member.diagnostics, fn diagnostic -> diagnostic.code end)
      end)

    assert :invalid_member in diagnostic_codes
    refute :invalid_identity in diagnostic_codes

    missing_parent = Map.delete(member(5, root), "parent")

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [missing_parent], 1)))

    [member] = selected.members
    assert :invalid_identity in Enum.map(member.diagnostics, & &1.code)
  end

  test "rejects a selected root missing its required parent key" do
    root = root(1)
    missing_parent = Map.delete(root, "parent")

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(missing_parent, [], 0)))

    assert :invalid_identity in Enum.map(selected.root.diagnostics, & &1.code)
  end

  test "detects a missing internal endpoint and accepts a cycle when every endpoint is present" do
    root = root(1)
    missing_internal = member(2, root, blocked_by: [endpoint(99)])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [missing_internal], 1)))

    assert :unresolved_internal_dependency in (selected.members
                                               |> hd()
                                               |> Map.fetch!(:diagnostics)
                                               |> Enum.map(& &1.code))

    unqualified_endpoint = endpoint(98) |> Map.delete("repository")
    unqualified = member(3, root, blocked_by: [unqualified_endpoint])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [unqualified], 1)))

    assert :invalid_dependency in (selected.members
                                   |> hd()
                                   |> Map.fetch!(:diagnostics)
                                   |> Enum.map(& &1.code))

    first = member(2, root, blocking: [endpoint(3)])
    second = member(3, root, blocking: [endpoint(2)])

    assert {:ok, %{candidate: %{members: members}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [first, second], 2)))

    assert Enum.map(members, & &1.identity.identifier) == ["2", "3"]
  end

  test "rejects native dependency endpoints with a matching node ID but contradictory locators" do
    root = root(1)

    for {locator, endpoint} <- contradictory_locators(root) do
      child = member(2, root, blocked_by: [endpoint])

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

      [selected_member] = selected.members
      [dependency] = selected_member.dependencies
      assert :invalid_endpoint_locator in Enum.map(dependency.diagnostics, & &1.code)
      assert :invalid_endpoint_locator in Enum.map(selected_member.diagnostics, & &1.code)

      if locator in [:database_id, :number] do
        refute :invalid_url in Enum.map(dependency.diagnostics, & &1.code)
      end
    end
  end

  test "rejects native dependency endpoints that contradict a canonical member locator" do
    root = root(1)
    canonical_member = member(3, root)

    for {_locator, endpoint} <- contradictory_locators(canonical_member) do
      child = member(2, root, blocking: [endpoint])

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root, [child, canonical_member], 2))
               )

      [selected_child, _canonical_member] = selected.members
      [dependency] = selected_child.dependencies
      assert :invalid_endpoint_locator in Enum.map(dependency.diagnostics, & &1.code)
      assert :invalid_endpoint_locator in Enum.map(selected_child.diagnostics, & &1.code)
    end
  end

  test "rejects parent endpoints with a matching node ID but contradictory locators" do
    root = root(1)

    for {_locator, parent} <- contradictory_locators(root) do
      child = member(2, root) |> Map.put("parent", parent)

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

      [selected_member] = selected.members
      assert :invalid_endpoint_locator in Enum.map(selected_member.diagnostics, & &1.code)
    end
  end

  test "uses case-insensitive repository names for native identity joins" do
    root = root(1)

    mixed_case_root =
      root
      |> endpoint_from()
      |> put_in(["repository", "owner", "login"], "OWNER")
      |> put_in(["repository", "name"], "REPO")

    child =
      member(2, root, blocking: [mixed_case_root])
      |> Map.put("parent", mixed_case_root)

    assert {:ok, %{candidate: %{members: [member]}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    assert member.parent_identity.owner == "OWNER"
    assert [%{kind: :native}] = member.dependencies
  end

  test "rejects identity-mismatched required URLs and omits mismatched optional external URLs" do
    root = root(1)

    for wrong_root_url <- [
          "https://github.com/owner/repo/issues/9",
          "https://github.com/owner/repo/pull/1"
        ] do
      root_with_wrong_url = Map.put(root, "url", wrong_root_url)

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root_with_wrong_url, [], 0))
               )

      assert :invalid_url in Enum.map(selected.root.diagnostics, & &1.code)
    end

    external = endpoint(44, "other", "repo") |> Map.put("url", "https://github.com/other/repo/issues/45")
    child = member(2, root, blocked_by: [external])

    assert {:ok, %{candidate: %{members: [member]}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    [dependency] = member.dependencies
    assert dependency.kind == :external
    assert dependency.url == nil
    assert :unsafe_external_url in Enum.map(dependency.diagnostics, & &1.code)

    for wrong_native_url <- [
          "https://github.com/owner/repo/issues/9",
          "https://github.com/other/repo/issues/1"
        ] do
      native_endpoint = endpoint(1) |> Map.put("url", wrong_native_url)
      child = member(2, root, blocking: [native_endpoint])

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root, [child], 1))
               )

      [member] = selected.members
      [dependency] = member.dependencies
      assert dependency.kind == :native
      assert :invalid_url in Enum.map(dependency.diagnostics, & &1.code)
      assert :invalid_dependency in Enum.map(member.diagnostics, & &1.code)
    end
  end

  test "rejects duplicate canonical native endpoints within one connection" do
    root = root(1)
    child = member(2, root, blocked_by: [endpoint(1), endpoint(1)])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    [member] = selected.members
    assert :duplicate_identity in Enum.map(member.diagnostics, & &1.code)
  end

  test "rejects duplicate canonical external endpoints without losing their classification" do
    root = root(1)
    external = endpoint(44, "other", "repo")
    child = member(2, root, blocked_by: [external, external])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    [member] = selected.members
    assert Enum.all?(member.dependencies, &(&1.kind == :external))
    assert :duplicate_identity in Enum.map(member.diagnostics, & &1.code)
  end

  test "rejects external dependency endpoints without joinable identities" do
    root = root(1)
    malformed_external = %{"url" => "https://github.com/other/repo/issues/44"}
    child = member(2, root, blocked_by: [malformed_external])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    [member] = selected.members
    [dependency] = member.dependencies
    assert dependency.kind == :external
    assert dependency.identity == nil
    assert :external_dependency in Enum.map(dependency.diagnostics, & &1.code)
    assert :invalid_identity in Enum.map(dependency.diagnostics, & &1.code)
    assert :invalid_dependency in Enum.map(member.diagnostics, & &1.code)
  end

  test "fails closed when a selected-member page changes the reported total" do
    root = root(1)

    responses = [
      selected_response(root, [member(2, root)], 3, has_next?: true, cursor: "member-page-2"),
      selected_response(root, [member(3, root)], 2)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 2, pages: 2, candidate: nil}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(queued_responses(responses), page_budget: 2, call_budget: 2)
             )
  end

  test "fails closed when a catalog page changes the reported total" do
    responses = [
      catalog_response([root(1)], 3, has_next?: true, cursor: "root-page-2"),
      catalog_response([root(2)], 2)
    ]

    assert {:error, %{error: :pagination_mismatch, calls: 2, pages: 2, candidate: nil}} =
             GitHubGraph.fetch_catalog(base_opts(queued_responses(responses), page_budget: 2, call_budget: 2))
  end

  test "rejects duplicate members with the same canonical identity" do
    root = root(1)
    duplicate = member(2, root)

    same_identity_with_different_casing =
      duplicate
      |> put_in(["repository", "owner", "login"], "OWNER")
      |> put_in(["repository", "name"], "REPO")

    assert {:error, %{error: :duplicate_identity, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [duplicate, same_identity_with_different_casing], 2))
             )

    assert length(selected.members) == 2
    assert SelectedRoot.status(selected) == :structurally_invalid
  end

  test "rejects a selected root duplicated as an executable member" do
    root = root(1)
    root_as_member = member(1, root)

    assert {:error, %{error: :duplicate_identity, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [root_as_member], 1))
             )

    [selected_member] = selected.members
    assert selected_member.identity == selected.root.identity
    assert SelectedRoot.status(selected) == :structurally_invalid
  end

  test "fails closed on duplicate native locator facts across the complete candidate" do
    root = root(1)

    database_collision = member(2, root) |> Map.put("databaseId", 1)
    member_collision = member(3, root) |> Map.put("databaseId", 2)
    number_and_url_collision = member(2, root) |> Map.put("number", 1) |> Map.put("url", root["url"])

    for members <- [
          [database_collision],
          [member(2, root), member_collision],
          [number_and_url_collision]
        ] do
      assert {:error, %{error: :duplicate_identity, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root, members, length(members)))
               )

      assert SelectedRoot.status(selected) == :structurally_invalid
    end

    duplicate_root = Map.put(root, "id", "Iowner-repo-other")

    assert {:error, %{error: :duplicate_identity, candidate: catalog}} =
             GitHubGraph.fetch_catalog(base_opts(catalog_response([root, duplicate_root], 2)))

    [first_entry | _rest] = catalog.entries
    assert {:provider_unavailable, _root} = Catalog.select(catalog, first_entry.identity)
  end

  test "classifies a unique member with no canonical identity as structurally invalid" do
    root = root(1)

    for missing_identity <- [
          member(2, root) |> Map.delete("id"),
          member(2, root) |> Map.delete("repository")
        ] do
      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root, [missing_identity], 1))
               )

      [selected_member] = selected.members
      assert :invalid_identity in Enum.map(selected_member.diagnostics, & &1.code)
    end
  end

  test "retains label-specific diagnostics for incomplete label connections" do
    root = root(1)

    for {labels, diagnostic} <- [
          {:missing, :invalid_label_connection},
          {%{}, :invalid_label_connection},
          {connection([], 1, []), :incomplete_labels},
          {connection([], 101, has_next?: true, cursor: "label-page-2"), :labels_overflow}
        ] do
      malformed_root = if labels == :missing, do: Map.delete(root, "labels"), else: Map.put(root, "labels", labels)

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(malformed_root, [], 0))
               )

      assert diagnostic in Enum.map(selected.root.diagnostics, & &1.code)
    end
  end

  test "fails closed on malformed root and member lifecycle facts" do
    root = root(1)

    missing_root_state = Map.delete(root, "state")

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(missing_root_state, [], 0)))

    assert :invalid_lifecycle in Enum.map(selected.root.diagnostics, & &1.code)

    missing_member_state = member(2, root) |> Map.delete("state")

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(root),
               base_opts(selected_response(root, [missing_member_state], 1))
             )

    assert :invalid_lifecycle in (selected.members
                                  |> hd()
                                  |> Map.fetch!(:diagnostics)
                                  |> Enum.map(& &1.code))

    closed_without_reason = root |> Map.put("state", "CLOSED") |> Map.put("stateReason", nil)

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(closed_without_reason, [], 0)))

    assert :invalid_lifecycle in Enum.map(selected.root.diagnostics, & &1.code)

    invalid_root_state = Map.put(root, "state", "UNRECOGNIZED")

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(invalid_root_state, [], 0)))

    assert :invalid_lifecycle in Enum.map(selected.root.diagnostics, & &1.code)
  end

  test "rejects missing and invalid OPEN state reasons while accepting an explicit null" do
    root = root(1)

    assert {:ok, %{candidate: %{root: accepted_root}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [], 0)))

    assert %{state: :open, state_reason: :none} = accepted_root.lifecycle

    for malformed_root <- [
          Map.delete(root, "stateReason"),
          Map.put(root, "stateReason", "UNRECOGNIZED")
        ] do
      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(malformed_root, [], 0)))

      assert :invalid_lifecycle in Enum.map(selected.root.diagnostics, & &1.code)
    end

    for malformed_member <- [
          member(2, root) |> Map.delete("stateReason"),
          member(2, root) |> Map.put("stateReason", "UNRECOGNIZED")
        ] do
      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(
                 identity(root),
                 base_opts(selected_response(root, [malformed_member], 1))
               )

      [selected_member] = selected.members
      assert :invalid_lifecycle in Enum.map(selected_member.diagnostics, & &1.code)
    end
  end

  test "requires the selected root to retain its controlled root label" do
    unlabeled_root = root(1) |> Map.put("labels", labels([]))

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(
               identity(unlabeled_root),
               base_opts(selected_response(unlabeled_root, [], 0))
             )

    assert :missing_root_label in Enum.map(selected.root.diagnostics, & &1.code)
  end

  test "accepts GitHub reopened lifecycle facts for open roots and members" do
    reopened_root = root(1) |> Map.put("stateReason", "REOPENED")
    reopened_member = member(2, reopened_root) |> Map.put("state", "OPEN") |> Map.put("stateReason", "REOPENED")

    assert {:ok, %{candidate: %{root: root, members: [member]}}} =
             GitHubGraph.fetch_selected_root(
               identity(reopened_root),
               base_opts(selected_response(reopened_root, [reopened_member], 1))
             )

    assert %{state: :open, state_reason: :reopened} = root.lifecycle
    assert %{state: :open, state_reason: :reopened} = member.lifecycle
  end

  test "preserves validated dependency counts when their connection is incomplete" do
    root = root(1)

    for {connection, expected_count} <- [
          {connection([], 101, has_next?: true, cursor: "dependency-page-2"), 101},
          {connection([endpoint(9)], 1, has_next?: true, cursor: "dependency-page-2"), 1},
          {connection([endpoint(9)], 2, []), 2},
          {%{"totalCount" => 3, "pageInfo" => %{}}, 3},
          {%{"totalCount" => 4, "nodes" => :malformed, "pageInfo" => %{}}, 4}
        ] do
      child = member(2, root) |> Map.put("blockedBy", connection)

      assert {:error, %{error: :structurally_invalid, candidate: selected}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

      [member] = selected.members
      assert member.connection_counts.blocked_by == expected_count
      assert :connection_overflow in Enum.map(member.diagnostics, & &1.code)
    end
  end

  test "accepts zero direct members and rejects a selected-member overflow" do
    root = root(1)

    assert {:ok, %{candidate: %{members: []}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [], 0)))

    first_page =
      selected_response(
        root,
        Enum.map(2..101, &member(&1, root)),
        101,
        has_next?: true,
        cursor: "member-page-2"
      )

    assert {:error, %{error: :member_overflow, calls: 1, pages: 1, candidate: nil}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(first_page))
  end

  test "keeps planning-label warnings renderable and distinguishes NOT_PLANNED" do
    root = root(1) |> Map.put("state", "CLOSED") |> Map.put("stateReason", "NOT_PLANNED")

    child =
      member(2, root, labels: ["phase:1", "phase:2", "build-lane:plan-graph", "complexity:4", "complexity:5"])

    assert {:ok, %{candidate: %{root: selected_root, members: [member]}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

    assert selected_root.lifecycle.state_reason == :not_planned
    assert Enum.sort(Enum.map(member.metadata.warnings, & &1.code)) == [:ambiguous_complexity, :ambiguous_phase]

    for {labels, warning} <- [
          {[], :missing_complexity},
          {["phase:2", "build-lane:plan-graph"], :missing_complexity},
          {["complexity:4", "build-lane:plan-graph"], :missing_phase},
          {["phase:2", "complexity:4"], :missing_lane},
          {["phase:2", "complexity:4", "build-lane:plan-graph", "build-lane:runtime"], :ambiguous_lane}
        ] do
      child = member(2, root, labels: labels)

      assert {:ok, %{candidate: %{members: [member]}}} =
               GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [child], 1)))

      assert warning in Enum.map(member.metadata.warnings, & &1.code)
    end
  end

  test "preserves sanitized provider observations for public graph failures" do
    failures = [
      {
        fn _ ->
          {:ok,
           %{
             status: 403,
             headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}],
             body: %{"message" => "rate limited"}
           }}
        end,
        {:github, :rate_limited, %{status: 403, remaining: 0, retry_after: 5}}
      },
      {
        fn _ ->
          {:ok,
           %{
             status: 401,
             headers: [{"x-ratelimit-remaining", "3"}],
             body: %{"message" => "not authorized"}
           }}
        end,
        {:github, :auth, %{status: 401, remaining: 3}}
      },
      {
        fn _ ->
          {:ok,
           %{
             status: 403,
             headers: [{"x-ratelimit-remaining", "7"}, {"x-ratelimit-reset", "1"}],
             body: %{"message" => "forbidden"}
           }}
        end,
        {:github, :permission, %{status: 403, remaining: 7, reset_at: "1970-01-01T00:00:01Z"}}
      },
      {
        fn _ ->
          {:ok,
           %{
             status: 429,
             headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}],
             body: %{"message" => "rate limited"}
           }}
        end,
        {:github, :rate_limited, %{status: 429, remaining: 0, retry_after: 5}}
      },
      {
        fn _ ->
          {:ok,
           %{
             status: 200,
             headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1"}],
             body: %{"errors" => [%{"message" => "private"}]}
           }}
        end,
        {:github, :rate_limited, %{status: 200, remaining: 0, reset_at: "1970-01-01T00:00:01Z"}}
      },
      {fn _ -> {:error, :timeout} end, {:github, :timeout, %{}}},
      {fn _ -> {:error, :nxdomain} end, {:github, :dns, %{}}}
    ]

    for {request_fun, error} <- failures do
      assert {:error, %{error: ^error, calls: 1, pages: 0} = result} =
               GitHubGraph.fetch_catalog(base_opts(request_fun))

      assert result.rate_limit == Map.drop(elem(error, 2), [:status])
    end

    root = root(1)
    {:ok, selected_success} = selected_response(root, [], 0)

    selected_success_request = fn _ ->
      headers = [{"x-ratelimit-remaining", "8"}, {"x-ratelimit-reset", "1"}, {"retry-after", "5"}]
      {:ok, %{selected_success | headers: headers}}
    end

    assert {:ok, %{rate_limit: %{remaining: 8, reset_at: "1970-01-01T00:00:01Z", retry_after: 5}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_success_request))

    selected_failure_request = fn _ ->
      {:ok,
       %{
         status: 403,
         headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "5"}],
         body: %{"message" => "rate limited"}
       }}
    end

    assert {:error, %{error: {:github, :rate_limited, %{status: 403, remaining: 0, retry_after: 5}}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_failure_request))
  end

  test "classifies typed GraphQL errors with non-exhausted headers through public graph reads" do
    rate_limited_catalog = fn _ ->
      {:ok,
       %{
         status: 200,
         headers: [{"x-ratelimit-remaining", "8"}, {"x-ratelimit-reset", "1"}],
         body: %{"errors" => [%{"type" => "RATE_LIMITED", "message" => "query quota exhausted"}]}
       }}
    end

    assert {:error,
            %{
              error: {:github, :rate_limited, %{status: 200, remaining: 8, reset_at: "1970-01-01T00:00:01Z"}},
              rate_limit: %{remaining: 8, reset_at: "1970-01-01T00:00:01Z"}
            }} = GitHubGraph.fetch_catalog(base_opts(rate_limited_catalog))

    permission_denied_selected = fn _ ->
      {:ok,
       %{
         status: 200,
         headers: [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "1"}],
         body: %{
           "errors" => [
             %{
               "extensions" => %{"code" => "FORBIDDEN"},
               "message" => "query access denied"
             }
           ]
         }
       }}
    end

    root = root(1)

    assert {:error,
            %{
              error: {:github, :permission, %{status: 200, remaining: 0, reset_at: "1970-01-01T00:00:01Z"}},
              rate_limit: %{remaining: 0, reset_at: "1970-01-01T00:00:01Z"}
            }} = GitHubGraph.fetch_selected_root(identity(root), base_opts(permission_denied_selected))

    malformed_extension_catalog = fn _ ->
      {:ok, %{status: 200, body: %{"errors" => [%{"extensions" => "malformed"}]}}}
    end

    assert {:error, %{error: :graphql_partial, calls: 1, pages: 0}} =
             GitHubGraph.fetch_catalog(base_opts(malformed_extension_catalog))
  end

  describe "public repository authority" do
    setup do
      previous_workflow_file_path = Application.get_env(:aiur, :workflow_file_path)
      fixture = Path.expand("../../fixtures/test.aiurconfig", __DIR__)

      Application.put_env(:aiur, :workflow_file_path, fixture)
      Aiur.WorkflowStore.force_reload()

      on_exit(fn ->
        case previous_workflow_file_path do
          nil -> Application.delete_env(:aiur, :workflow_file_path)
          path -> Application.put_env(:aiur, :workflow_file_path, path)
        end

        if Process.whereis(Aiur.WorkflowStore) do
          try do
            Aiur.WorkflowStore.force_reload()
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      :ok
    end

    test "the Client facade retains graph contracts and body-free queries" do
      configured_repository = {"test-org", "test-repo"}
      root = root(1, "test-org", "test-repo")

      request_fun = fn %{body: %{"query" => query}} ->
        refute query =~ "body"
        selected_response(root, [], 0)
      end

      assert {:ok, %{candidate: %{root: %{identity: selected_identity}}}} =
               Client.fetch_build_order_selected_root(identity(root, configured_repository), public_opts(request_fun))

      assert selected_identity == identity(root, configured_repository)

      catalog_request_fun = fn %{body: %{"query" => query}} ->
        refute query =~ "body"
        assert query =~ "subIssues(first: 100)"

        assert String.replace(query, ~r/\s+/, " ") =~
                 "subIssues(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { state stateReason labels(first: 20)"

        catalog_response([], 0)
      end

      assert {:ok, %{candidate: %{entries: []}}} =
               Client.fetch_build_order_catalog(public_opts(catalog_request_fun))
    end

    test "public graph reads derive their authority from validated configuration" do
      foreign_request = fn _request -> flunk("foreign authority must not reach GitHub") end

      assert {:error, %{error: :invalid_planning_authority, calls: 0, pages: 0}} =
               ProductionGraph.fetch_catalog(repository: {"foreign-owner", "foreign-repo"}, request_fun: foreign_request)

      for invalid_bound <- [[root_limit: 1], [page_budget: 1], [call_budget: 1]] do
        assert {:error, %{error: :invalid_planning_authority, calls: 0, pages: 0}} =
                 ProductionGraph.fetch_catalog(Keyword.put(invalid_bound, :request_fun, foreign_request))
      end

      root = root(1, "test-org", "test-repo")

      configured_request = fn %{body: %{"variables" => variables}} ->
        assert variables["owner"] == "test-org"
        assert variables["repo"] == "test-repo"
        catalog_response([root], 1)
      end

      assert {:ok, %{candidate: %{entries: [_entry]}}} =
               ProductionGraph.fetch_catalog(
                 repository: {"TEST-ORG", "TEST-REPO"},
                 root_limit: 100,
                 page_budget: 4,
                 call_budget: 4,
                 request_fun: configured_request
               )
    end
  end

  defp base_opts(response_or_request_fun, overrides \\ []) do
    request_fun =
      if is_function(response_or_request_fun, 1) do
        response_or_request_fun
      else
        queued_responses([response_or_request_fun])
      end

    [
      repository: @repository,
      request_fun: request_fun,
      root_limit: 100,
      page_budget: 4,
      call_budget: 4
    ]
    |> Keyword.merge(overrides)
  end

  defp public_opts(request_fun), do: [request_fun: request_fun]

  defp queued_responses(responses) do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(parent, {:graph_request, request.body["variables"]})

      Agent.get_and_update(agent, fn
        [response | rest] -> {response, rest}
        [] -> raise "unexpected GraphQL request"
      end)
    end
  end

  defp drain_requests, do: drain_requests([])

  defp drain_requests(acc) do
    receive do
      {:graph_request, variables} -> drain_requests([variables | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp catalog_response(nodes, total, opts \\ []) do
    graphql_response(%{"data" => %{"repository" => %{"issues" => connection(nodes, total, opts)}}})
  end

  defp selected_response(root, members, total, opts \\ []) do
    root = Map.put(root, "subIssues", connection(members, total, opts))
    graphql_response(%{"data" => %{"repository" => %{"issue" => root}}})
  end

  defp graphql_response(body), do: {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "99"}], body: body}}
  defp graphql_error, do: {:ok, %{status: 200, body: %{"errors" => [%{"message" => "redacted"}]}}}

  defp connection(nodes, total, opts) do
    %{
      "nodes" => nodes,
      "totalCount" => total,
      "pageInfo" => %{
        "hasNextPage" => Keyword.get(opts, :has_next?, false),
        "endCursor" => Keyword.get(opts, :cursor)
      }
    }
  end

  defp without_terminal_cursor({:ok, %{body: body} = response}, path) do
    {:ok, %{response | body: update_in(body, path, &without_terminal_cursor/1)}}
  end

  defp without_terminal_cursor(connection) do
    update_in(connection, ["pageInfo"], &Map.delete(&1, "endCursor"))
  end

  defp root(number, owner \\ "owner", repo \\ "repo") do
    issue_node(number, owner, repo)
    |> Map.put("labels", labels(["build-order"]))
  end

  defp member(number, root, opts \\ []) do
    issue_node(number)
    |> Map.put("parent", endpoint_from(root))
    |> Map.put("labels", labels(Keyword.get(opts, :labels, ["phase:2", "build-lane:plan-graph", "complexity:4"])))
    |> Map.put("blockedBy", dependency_connection(Keyword.get(opts, :blocked_by, [])))
    |> Map.put("blocking", dependency_connection(Keyword.get(opts, :blocking, [])))
  end

  defp issue_node(number, owner \\ "owner", repo \\ "repo") do
    %{
      "id" => "I#{owner}-#{repo}-#{number}",
      "databaseId" => number,
      "number" => number,
      "title" => "Issue #{number}",
      "url" => "https://github.com/#{owner}/#{repo}/issues/#{number}",
      "state" => if(rem(number, 2) == 0, do: "CLOSED", else: "OPEN"),
      "stateReason" => if(rem(number, 2) == 0, do: "COMPLETED", else: nil),
      "createdAt" => "2026-07-13T12:00:00Z",
      "updatedAt" => "2026-07-13T12:30:00Z",
      "repository" => repository(owner, repo),
      "parent" => nil,
      "labels" => labels(["build-order"])
    }
  end

  defp endpoint(number, owner \\ "owner", repo \\ "repo"), do: endpoint_from(issue_node(number, owner, repo))

  defp endpoint_from(node) do
    Map.take(node, ["id", "databaseId", "number", "url", "repository"])
  end

  defp contradictory_locators(root) do
    endpoint = endpoint_from(root)

    [
      {:database_id, Map.put(endpoint, "databaseId", 999)},
      {:number, endpoint |> Map.put("number", 999) |> Map.put("url", "https://github.com/owner/repo/issues/999")},
      {:url, Map.put(endpoint, "url", "https://github.com/owner/repo/issues/999")}
    ]
  end

  defp identity(node, configured_repository \\ @repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{
          "node_id" => node["id"],
          "database_id" => node["databaseId"],
          "number" => node["number"],
          "repository" => node["repository"]
        },
        configured_repository,
        configured_repository
      )

    identity
  end

  defp repository(owner, repo), do: %{"name" => repo, "owner" => %{"login" => owner}}
  defp labels(names), do: connection(Enum.map(names, &%{"name" => &1}), length(names), [])
  defp dependency_connection(nodes), do: connection(nodes, length(nodes), [])
end
