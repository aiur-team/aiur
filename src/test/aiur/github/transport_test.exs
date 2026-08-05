defmodule Aiur.GitHub.TransportTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

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

  test "logs pressure from rate-limit headers on successful GraphQL reads" do
    request_fun = fn _ ->
      {:ok,
       %{
         status: 200,
         headers: [
           {"x-ratelimit-resource", "graphql"},
           {"x-ratelimit-remaining", "499"},
           {"x-ratelimit-limit", "5000"},
           {"x-ratelimit-reset", "1785416400"}
         ],
         body: %{"data" => %{"ok" => true}}
       }}
    end

    log = capture_log(fn -> assert {:ok, %{"data" => %{"ok" => true}}} = Transport.github_graphql(request_fun, "token", "query", %{}) end)

    assert log =~ "github_rate_budget_pressure resource=graphql remaining=499 limit=5000"
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

  test "carries and classifies a GraphQL response ceiling" do
    response = %{
      status: 200,
      private: %{aiur_response_too_large: true},
      body: ""
    }

    request_fun = fn request ->
      assert request.max_response_bytes == 32_768
      {:ok, response}
    end

    assert {:error, :github_graphql_response_too_large, ^response} =
             Transport.github_graphql_response(request_fun, "token", "query", %{}, max_response_bytes: 32_768)

    assert {:error, :github_graphql_response_too_large} =
             Transport.github_graphql(request_fun, "token", "query", %{}, max_response_bytes: 32_768)
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

  describe "conditional reads" do
    @transport_test_options_key :github_transport_test_options

    setup do
      prev = Application.get_env(:aiur, @transport_test_options_key)
      Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:aiur, @transport_test_options_key)
          value -> Application.put_env(:aiur, @transport_test_options_key, value)
        end
      end)

      :ok
    end

    test "default_request_fun sends a cached etag as an If-None-Match request header" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:if_none_match, Plug.Conn.get_req_header(conn, "if-none-match")})
        Req.Test.json(conn, [])
      end)

      assert {:ok, _response} =
               Transport.default_request_fun(%{
                 method: :get,
                 url: "https://api.github.com/repos/owner/repo/issues",
                 token: "token",
                 etag: "W/\"abc123\""
               })

      assert_receive {:if_none_match, ["W/\"abc123\""]}
    end

    test "default_request_fun omits If-None-Match when no etag is cached" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:if_none_match, Plug.Conn.get_req_header(conn, "if-none-match")})
        Req.Test.json(conn, [])
      end)

      assert {:ok, _response} =
               Transport.default_request_fun(%{
                 method: :get,
                 url: "https://api.github.com/repos/owner/repo/issues",
                 token: "token"
               })

      assert_receive {:if_none_match, []}
    end
  end

  describe "fetch_json_list_conditional/4" do
    test "returns the body and the response etag on 200" do
      request_fun = fn request ->
        assert request.etag == "etag-old"
        {:ok, %{status: 200, headers: [{"etag", "etag-new"}], body: [%{"id" => 1}]}}
      end

      assert {:ok, [%{"id" => 1}], "etag-new"} =
               Transport.fetch_json_list_conditional(request_fun, "token", "https://api.github.com/x", "etag-old")
    end

    test "keeps the cached etag on 200 when the response omits one" do
      request_fun = fn _request -> {:ok, %{status: 200, headers: [], body: []}} end

      assert {:ok, [], "etag-old"} =
               Transport.fetch_json_list_conditional(request_fun, "token", "https://api.github.com/x", "etag-old")
    end

    test "returns :not_modified with the retained etag on 304" do
      request_fun = fn request ->
        assert request.etag == "etag-old"
        {:ok, %{status: 304, headers: [], body: ""}}
      end

      assert {:not_modified, "etag-old"} =
               Transport.fetch_json_list_conditional(request_fun, "token", "https://api.github.com/x", "etag-old")
    end

    test "omits the etag field entirely when no etag is cached" do
      request_fun = fn request ->
        refute Map.has_key?(request, :etag)
        {:ok, %{status: 200, headers: [], body: []}}
      end

      assert {:ok, [], nil} = Transport.fetch_json_list_conditional(request_fun, "token", "https://api.github.com/x", nil)
    end

    test "classifies a non-2xx status as an error" do
      request_fun = fn _request -> {:ok, %{status: 403, headers: [], body: %{"message" => "forbidden"}}} end

      assert {:error, _reason} =
               Transport.fetch_json_list_conditional(request_fun, "token", "https://api.github.com/x", "etag-old")
    end
  end
end
