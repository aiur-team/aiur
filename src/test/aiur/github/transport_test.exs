defmodule Aiur.GitHub.TransportTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Transport

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "config-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    :ok
  end

  test "exposes GitHub base URLs" do
    assert Transport.base_url() == "https://api.github.com"
    assert Transport.graphql_url() == "https://api.github.com/graphql"
  end

  test "parses configured owner and repo" do
    assert Transport.parse_repo() == {:ok, {"owner", "repo"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo/extra"
    )

    assert Transport.parse_repo() == {:error, {:invalid_github_repo, "owner/repo/extra"}}
  end

  test "resolves token from opts, request_fun seam, then config" do
    assert Transport.require_token(token: "opts-token") == {:ok, "opts-token"}
    assert Transport.require_token(request_fun: fn _ -> :ok end) == {:ok, "test-gh-token"}
    assert Transport.require_token([]) == {:ok, "config-token"}

    System.delete_env("GITHUB_TOKEN")
    :persistent_term.erase(@token_cache_key)

    assert Transport.require_token([]) == {:error, :missing_github_token}
  end

  test "builds default and versioned GitHub headers" do
    assert Transport.github_headers("token", %{}) == [
             {"Authorization", "Bearer token"},
             {"Accept", "application/vnd.github+json"},
             {"X-GitHub-Api-Version", "2022-11-28"}
           ]

    assert {"X-GitHub-Api-Version", "2026-03-10"} in Transport.github_headers("token", %{api_version: "2026-03-10"})
  end

  test "handles GraphQL success, GraphQL errors, and HTTP errors" do
    request_fun = fn req ->
      assert req.method == :post
      assert req.url == Transport.graphql_url()
      assert req.token == "token"
      assert req.body == %{"query" => "query", "variables" => %{"id" => "1"}}

      {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert Transport.github_graphql(request_fun, "token", "query", %{"id" => "1"}) ==
             {:ok, %{"data" => %{"ok" => true}}}

    graph_error = fn _ -> {:ok, %{status: 200, body: %{"errors" => [%{"message" => "bad"}]}}} end

    assert {:error, {:github_graphql_errors, [%{"message" => "bad"}]}} =
             Transport.github_graphql(graph_error, "token", "query", %{})

    exhausted_graph_error = fn _ ->
      {:ok,
       %{
         status: 200,
         headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "7"}],
         body: %{"errors" => [%{"message" => "rate limit exceeded"}]}
       }}
    end

    assert {:error, {:github_graphql_errors, [%{"message" => "rate limit exceeded"}]}} =
             Transport.github_graphql(exhausted_graph_error, "token", "query", %{})

    http_error = fn _ -> {:ok, %{status: 401, body: %{"message" => "Bad credentials"}}} end

    assert {:error, {:github, :auth, %{status: 401, message: "Bad credentials"}}} =
             Transport.github_graphql(http_error, "token", "query", %{})
  end

  test "returns GraphQL response headers for bounded provider observation" do
    request_fun = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: [{"x-ratelimit-remaining", "99"}],
         body: %{"data" => %{"repository" => %{}}}
       }}
    end

    assert {:ok, %{"data" => %{"repository" => %{}}}, %{headers: headers}} =
             Transport.github_graphql_response(request_fun, "token", "query", %{})

    assert Transport.header(headers, "x-ratelimit-remaining") == "99"
  end

  test "rejects malformed HTTP-200 GraphQL envelopes" do
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

      assert {:error, :invalid_graphql_response, ^response} =
               Transport.github_graphql_response(request_fun, "token", "query", %{})

      assert {:error, :invalid_graphql_response} =
               Transport.github_graphql(request_fun, "token", "query", %{})
    end
  end

  test "rejects invalid status shapes and unexpected GraphQL transport results" do
    for {result, response} <- [
          {{:ok, %{status: "200", body: %{}}}, %{status: "200", body: %{}}},
          {{:ok, %{status: nil, body: %{}}}, %{status: nil, body: %{}}},
          {{:ok, %{status: 700, body: %{}}}, %{status: 700, body: %{}}},
          {{:ok, %{}}, %{}},
          {{:ok, "unexpected"}, nil},
          {:unexpected, nil}
        ] do
      request_fun = fn _request -> result end

      assert {:error, :invalid_graphql_response, ^response} =
               Transport.github_graphql_response(request_fun, "token", "query", %{})

      assert {:error, :invalid_graphql_response} =
               Transport.github_graphql(request_fun, "token", "query", %{})
    end
  end

  test "fetches JSON lists and classifies failures" do
    ok = fn %{method: :get, url: "https://example.test", token: "token"} ->
      {:ok, %{status: 200, body: [%{"name" => "file"}]}}
    end

    assert Transport.fetch_json_list(ok, "token", "https://example.test") ==
             {:ok, [%{"name" => "file"}]}

    failed = fn _ -> {:error, :timeout} end

    assert Transport.fetch_json_list(failed, "token", "https://example.test") ==
             {:error, {:github, :timeout, %{reason: :timeout}}}
  end

  test "reads headers case-insensitively and parses pagination and poll interval" do
    headers = [
      {"Link", ~s(<https://api.github.com/page/2>; rel="next")},
      {"X-Poll-Interval", "15"}
    ]

    assert Transport.header(headers, "link") =~ "/page/2"
    assert Transport.parse_next_page_url(headers) == "https://api.github.com/page/2"
    assert Transport.poll_interval(headers) == 15
    assert Transport.poll_interval([]) == 60
    assert Transport.header(%{"etag" => ["abc"]}, "ETag") == "abc"
    assert Transport.header(nil, "etag") == nil
  end

  test "conditionally puts query params" do
    assert Transport.maybe_put_query(%{}, "since", nil) == %{}
    assert Transport.maybe_put_query(%{}, "since", "now") == %{"since" => "now"}
  end
end
