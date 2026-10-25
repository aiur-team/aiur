defmodule Aiur.GitHub.Client.AuthAndErrorsTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.BuildOrder.GitHubGraph
  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  describe "preflight_auth/1" do
    test "checks rate limit, repository, and issues endpoints with the active token" do
      parent = self()

      request_fun = fn %{method: :get, url: url, token: token} ->
        assert token == "test-gh-token"
        send(parent, {:preflight_url, url})
        {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
      end

      assert :ok =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert_received {:preflight_url, "https://api.github.com/rate_limit"}
      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo"}

      assert_received {:preflight_url, "https://api.github.com/repos/owner/repo/issues?state=open&per_page=1"}
    end

    test "reports invalid GITHUB_TOKEN without leaking token material" do
      request_fun = fn %{url: url} ->
        if url =~ "/rate_limit" do
          {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}
        else
          flunk("preflight should stop after the failed endpoint")
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end
               )

      assert diagnostic.reason == :invalid_or_expired_token
      assert diagnostic.endpoint == :rate_limit
      assert diagnostic.status == 401
      assert diagnostic.gh_keyring_status == :available
      assert diagnostic.message =~ "GITHUB_TOKEN"
      assert diagnostic.message =~ "takes precedence over `gh` keyring auth"
      assert diagnostic.message =~ "gh` keyring auth appears usable"
      refute diagnostic.message =~ "test-gh-token"
    end

    test "fails when the REST core rate limit is exhausted" do
      reset = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

      request_fun = fn %{url: url} ->
        assert url =~ "/rate_limit"

        {:ok,
         %{
           status: 200,
           headers: [
             {"x-ratelimit-remaining", "0"},
             {"x-ratelimit-reset", Integer.to_string(reset)}
           ],
           body: %{"resources" => %{"core" => %{"remaining" => 0}}}
         }}
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :unavailable} end
               )

      assert diagnostic.reason == :rate_limited
      assert diagnostic.rate_limit_remaining == 0
      assert diagnostic.message =~ "rate limit is exhausted"
      assert diagnostic.message =~ "GITHUB_TOKEN"
    end

    test "classifies DNS request failures during preflight" do
      request_fun = fn %{url: url} ->
        assert url =~ "/rate_limit"
        {:error, %Req.TransportError{reason: :nxdomain}}
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :unavailable} end
               )

      assert diagnostic.reason == :dns
      assert diagnostic.classification == :dns
      assert diagnostic.detail == %{reason: :nxdomain}
      assert diagnostic.message =~ "DNS resolution failed"
      assert diagnostic.message =~ "api.github.com"
    end

    test "distinguishes endpoint-specific forbidden responses" do
      request_fun = fn %{url: url} ->
        cond do
          url =~ "/rate_limit" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}

          url =~ "/repos/owner/repo/issues" ->
            {:ok,
             %{
               status: 403,
               headers: [{"x-ratelimit-remaining", "42"}],
               body: %{"message" => "Resource not accessible by personal access token"}
             }}

          url =~ "/repos/owner/repo" ->
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
        end
      end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               Client.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert diagnostic.reason == :forbidden
      assert diagnostic.endpoint == :issues
      assert diagnostic.rate_limit_remaining == 42
      assert diagnostic.message =~ "missing repository permissions"
      assert diagnostic.message =~ "repos/owner/repo/issues?per_page=1"
    end
  end

  describe "classify_error/1 (error taxonomy)" do
    # Operators must be able to tell a DNS/connectivity failure apart from an
    # auth failure to fix flaky GitHub access (#617): a DNS outage and an
    # expired token need different remediation, but both used to flatten into
    # the opaque {:github_api_request, reason} tuple. Each branch below pins a
    # distinct, pattern-matchable classification so callers can route on it.

    test "an :nxdomain transport error classifies as :dns" do
      assert {:github, :dns, detail} =
               Client.classify_error({:error, %Req.TransportError{reason: :nxdomain}})

      assert detail.reason == :nxdomain
    end

    test "a Mint.TransportError :nxdomain also classifies as :dns" do
      # Req wraps Mint, but classification keys off the shared :reason field so
      # either struct surfaces identically.
      assert {:github, :dns, _detail} =
               Client.classify_error({:error, %Mint.TransportError{reason: :nxdomain}})
    end

    test "a :timeout / :closed / :econnrefused transport error classifies as :timeout" do
      for reason <- [:timeout, :closed, :econnrefused] do
        assert {:github, :timeout, %{reason: ^reason}} =
                 Client.classify_error({:error, %Req.TransportError{reason: reason}})
      end
    end

    test "a TLS alert transport error classifies as :tls" do
      assert {:github, :tls, _detail} =
               Client.classify_error({:error, %Req.TransportError{reason: {:tls_alert, {:handshake_failure, "x"}}}})
    end

    test "an HTTP 401 classifies as :auth" do
      assert {:github, :auth, %{status: 401}} =
               Client.classify_error(%{status: 401, headers: [], body: %{}})
    end

    test "an HTTP 403 rate-limit response classifies as :rate_limited" do
      response = %{
        status: 403,
        headers: [{"x-ratelimit-remaining", "0"}, {"retry-after", "42"}, {"x-ratelimit-reset", "1900000000"}],
        body: %{"message" => "API rate limit exceeded"}
      }

      assert {:github, :rate_limited, detail} = Client.classify_error(response)
      assert detail.retry_after == 42
      assert detail.reset_at == "2030-03-17T17:46:40Z"
    end

    test "a plain HTTP 403 (no rate-limit signal) classifies as :http" do
      assert {:github, :http, %{status: 403}} =
               Client.classify_error(%{status: 403, headers: [], body: %{}})
    end

    test "an unmapped 5xx status classifies as :http" do
      assert {:github, :http, %{status: 503}} =
               Client.classify_error(%{status: 503, headers: [], body: %{}})
    end
  end

  describe "transport failures surface the taxonomy (not opaque tuples)" do
    test "fetch_repo_events maps an :nxdomain DNS failure to {:github, :dns, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :nxdomain}} end

      assert {:error, {:github, :dns, _detail}} =
               Client.fetch_repo_events(request_fun: request_fun, token: "test-gh-token")
    end

    test "create_comment maps a transport timeout to {:github, :timeout, _}" do
      request_fun = fn _ -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, {:github, :timeout, _detail}} =
               Client.create_comment("42", "hi", request_fun: request_fun)
    end
  end

  describe "bounded Build Order planning adapter" do
    test "reads the catalog through the separate bounded planning adapter" do
      request_fun = fn %{method: :post, body: body} ->
        assert body["query"] =~ "AiurBuildOrderCatalog"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "repository" => %{
                 "issues" => %{
                   "nodes" => [],
                   "totalCount" => 0,
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }
         }}
      end

      assert {:ok, %{candidate: %{entries: []}, calls: 1, pages: 1}} =
               GitHubGraph.fetch_catalog(request_fun: request_fun)
    end
  end
end
