defmodule Aiur.BuildOrder.GitHubGraph.SelectedRootTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.Catalog
  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph
  alias Aiur.BuildOrder.SelectedRoot

  # `Metadata.parse/1` maps a missing `build-lane:`/`phase:` label onto
  # `:unassigned`/`:unphased`, and the pack path counts that placeholder as one
  # distinct group. Pin the exact degenerate values so the GitHub path cannot
  # drift away from that shared rule behind an `is_integer/1` assertion. These
  # counts live on the selected-root path, whose query still carries labels.
  test "counts unlabelled selected-root members as one distinct epic and wave" do
    labelled_root = root(1)
    unlabelled_root = root(5)

    mixed = [
      member(2, labelled_root, labels: ["phase:1", "build-lane:runtime"]),
      member(3, labelled_root, labels: ["complexity:2"])
    ]

    unlabelled = [
      member(6, unlabelled_root, labels: []),
      member(7, unlabelled_root, labels: ["complexity:1"])
    ]

    assert {:ok, %{candidate: %{root: mixed_summary}}} =
             GitHubGraph.fetch_selected_root(identity(labelled_root), base_opts(selected_response(labelled_root, mixed, 2)))

    # One real lane plus the `:unassigned` placeholder are two distinct groups.
    assert mixed_summary.epic_count == 2
    assert mixed_summary.phase_count == 2

    assert {:ok, %{candidate: %{root: unlabelled_summary}}} =
             GitHubGraph.fetch_selected_root(
               identity(unlabelled_root),
               base_opts(selected_response(unlabelled_root, unlabelled, 2))
             )

    # Every member unlabelled collapses onto the single placeholder group.
    assert unlabelled_summary.member_count == 2
    assert unlabelled_summary.epic_count == 1
    assert unlabelled_summary.phase_count == 1
  end

  test "leaves selected-root counts unresolved when member labels are truncated" do
    root = root(1)

    truncated =
      member(2, root)
      |> Map.put("labels", connection(Enum.map(1..20, &%{"name" => "label-#{&1}"}), 21, has_next?: true, cursor: "more-labels"))

    # Truncated labels also make the member itself structurally invalid, so the
    # read fails; the retained candidate is where the root's metrics are read.
    assert {:error, %{error: :structurally_invalid, candidate: %{root: summary}}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [truncated], 1)))

    assert summary.member_count == 1
    assert is_nil(summary.epic_count)
    assert is_nil(summary.phase_count)
    assert summary.progress == 100
    assert summary.progress_resolution == :resolved
    assert summary.progress_resolved_count == 1
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
end
