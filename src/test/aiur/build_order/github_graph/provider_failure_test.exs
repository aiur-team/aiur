defmodule Aiur.BuildOrder.GitHubGraph.ProviderFailureTest do
  use ExUnit.Case, async: false

  import Aiur.BuildOrder.GitHubGraphFixtures

  alias Aiur.BuildOrder.GitHubGraph.TestAdapter, as: GitHubGraph

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
      # The transport `:reason` is retained: it is the only thing separating a
      # genuine timeout from a refused connection, which `Errors` also tags
      # `:timeout` (#2250). It is a bounded atom, never a payload.
      {fn _ -> {:error, :timeout} end, {:github, :timeout, %{reason: :timeout}}},
      {fn _ -> {:error, :econnrefused} end, {:github, :timeout, %{reason: :econnrefused}}},
      {fn _ -> {:error, :nxdomain} end, {:github, :dns, %{reason: :nxdomain}}}
    ]

    for {request_fun, error} <- failures do
      assert {:error, %{error: ^error, calls: 1, pages: 0} = result} =
               GitHubGraph.fetch_catalog(base_opts(request_fun))

      assert result.rate_limit == Map.drop(elem(error, 2), [:status, :reason])
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
end
