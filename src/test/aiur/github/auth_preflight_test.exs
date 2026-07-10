defmodule Aiur.GitHub.AuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "preflight-token")

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

  test "checks rate limit, repository, and issues endpoints in order" do
    parent = self()

    request_fun = fn %{method: :get, url: url, token: token, preflight?: true} ->
      assert token == "preflight-token"
      send(parent, {:url, url})
      {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
    end

    assert :ok =
             AuthPreflight.preflight_auth(
               request_fun: request_fun,
               gh_auth_status_fun: fn -> {:ok, :not_installed} end
             )

    assert_received {:url, "https://api.github.com/rate_limit"}
    assert_received {:url, "https://api.github.com/repos/owner/repo"}
    assert_received {:url, "https://api.github.com/repos/owner/repo/issues?state=open&per_page=1"}
  end

  test "halts on the first failed endpoint and enriches diagnostics without token material" do
    request_fun = fn %{url: "https://api.github.com/rate_limit"} ->
      {:ok,
       %{
         status: 403,
         headers: [{"x-ratelimit-remaining", "0"}],
         body: %{"message" => "API rate limit exceeded"}
       }}
    end

    assert {:error, {:github_auth_preflight_failed, diagnostic}} =
             AuthPreflight.preflight_auth(
               request_fun: request_fun,
               gh_auth_status_fun: fn -> {:ok, :available} end
             )

    assert diagnostic.reason == :rate_limited
    assert diagnostic.endpoint == :rate_limit
    assert diagnostic.rate_limit_remaining == 0
    assert diagnostic.gh_keyring_status == :available
    assert diagnostic.message =~ "GITHUB_TOKEN"
    refute inspect(diagnostic) =~ "preflight-token"
  end

  test "formats diagnostic maps and plain fallback reasons" do
    reason = {:github_auth_preflight_failed, %{message: "friendly"}}

    assert AuthPreflight.format_auth_preflight_error(reason) == "friendly"
    assert AuthPreflight.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
  end
end
