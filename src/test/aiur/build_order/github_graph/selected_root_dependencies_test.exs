defmodule Aiur.BuildOrder.GitHubGraph.SelectedRootDependenciesTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph
  alias Aiur.BuildOrder.ProviderResult
  alias Aiur.BuildOrder.SelectedRoot

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

  # A same-repository blocker that is not a member of this root is an ordinary
  # fact about a Build Order still in flight, not a defect in the member. The
  # member stays clean and the read still succeeds — failing the read here
  # erased every member of a 27-member root from the page (#1777), and flagging
  # the member only produced the false "configured-repository dependency is
  # missing from this graph" warning (#1872).
  test "records a missing internal endpoint without failing the read" do
    root = root(1)
    missing_internal = member(2, root, blocked_by: [endpoint(99)])

    assert {:ok, %{candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, [missing_internal], 1)))

    assert SelectedRoot.structurally_valid?(selected)
    assert selected.diagnostics == []
    assert length(selected.members) == 1

    refute :unresolved_internal_dependency in (selected.members
                                               |> hd()
                                               |> Map.fetch!(:diagnostics)
                                               |> Enum.map(& &1.code))
  end

  # The failing root had 24 closed and 3 open members, and only roots with open
  # members failed — open members are the ones that acquire blockers filed
  # outside their own Build Order (#1777).
  test "reads a root whose open members are blocked by issues outside the root" do
    root = root(1)
    closed_member = member(2, root)
    open_member = member(3, root, blocked_by: [endpoint(99)])
    second_open_member = member(5, root, blocked_by: [endpoint(98)], blocking: [endpoint(3)])
    members = [closed_member, open_member, second_open_member]

    assert {:ok, %ProviderResult{status: :complete, candidate: selected}} =
             GitHubGraph.fetch_selected_root(identity(root), base_opts(selected_response(root, members, 3)))

    assert Enum.map(selected.members, & &1.identity.identifier) == ["2", "3", "5"]
    assert Enum.map(selected.members, & &1.lifecycle.state) == [:closed, :open, :open]
    assert SelectedRoot.status(selected) == :ready

    # Cross-root blockers are ordinary, so no member carries the misleading
    # "missing from this graph" diagnostic.
    assert Enum.all?(selected.members, &(:unresolved_internal_dependency not in Enum.map(&1.diagnostics, fn d -> d.code end)))
  end

  test "rejects an unqualified endpoint and accepts a cycle when every endpoint is present" do
    root = root(1)

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
end
