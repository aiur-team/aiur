defmodule Aiur.BuildOrder.GitHubGraphTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Catalog, GitHubGraph, ProviderResult}

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
               1,
               base_opts(queued_responses(responses), page_budget: 4, call_budget: 4)
             )

    assert result.status == :complete
    assert result.calls == 4
    assert result.pages == 4
    assert length(result.candidate.members) == 100
    assert Enum.all?(result.candidate.members, &(&1.parent_identity == result.candidate.root.identity))
    assert Enum.map(drain_requests(), &Map.fetch!(&1, "pageSize")) == [25, 25, 25, 25]
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
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [child], 1)))

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
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [duplicate, duplicate], 2)))

    assert length(selected.members) == 2

    missing_endpoint = member(3, root, blocked_by: [%{}])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [missing_endpoint], 1)))

    [member] = selected.members
    assert :invalid_dependency in Enum.map(member.diagnostics, & &1.code)

    missing_parent = Map.put(member(4, root), "parent", nil)

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [missing_parent], 1)))

    diagnostic_codes =
      Enum.flat_map(selected.members, fn member ->
        Enum.map(member.diagnostics, fn diagnostic -> diagnostic.code end)
      end)

    assert :invalid_member in diagnostic_codes
  end

  test "detects a missing internal endpoint and accepts a cycle when every endpoint is present" do
    root = root(1)
    missing_internal = member(2, root, blocked_by: [endpoint(99)])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [missing_internal], 1)))

    assert :unresolved_internal_dependency in (selected.members
                                               |> hd()
                                               |> Map.fetch!(:diagnostics)
                                               |> Enum.map(& &1.code))

    unqualified_endpoint = endpoint(98) |> Map.delete("repository")
    unqualified = member(3, root, blocked_by: [unqualified_endpoint])

    assert {:error, %{error: :structurally_invalid, candidate: selected}} =
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [unqualified], 1)))

    assert :invalid_dependency in (selected.members
                                   |> hd()
                                   |> Map.fetch!(:diagnostics)
                                   |> Enum.map(& &1.code))

    first = member(2, root, blocking: [endpoint(3)])
    second = member(3, root, blocking: [endpoint(2)])

    assert {:ok, %{candidate: %{members: members}}} =
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [first, second], 2)))

    assert Enum.map(members, & &1.identity.identifier) == ["2", "3"]
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
             GitHubGraph.fetch_selected_root(1, base_opts(selected_response(root, [child], 1)))

    assert member.parent_identity.owner == "OWNER"
    assert [%{kind: :native}] = member.dependencies
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

  defp root(number) do
    issue_node(number)
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

  defp repository(owner, repo), do: %{"name" => repo, "owner" => %{"login" => owner}}
  defp labels(names), do: connection(Enum.map(names, &%{"name" => &1}), length(names), [])
  defp dependency_connection(nodes), do: connection(nodes, length(nodes), [])
end
