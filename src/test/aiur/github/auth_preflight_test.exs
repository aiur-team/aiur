defmodule Aiur.GitHub.AuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.ReadCache

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @source_cache_key {Aiur.GitHub.Config, :resolved_token_source}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    prev_source = :persistent_term.get(@source_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    :persistent_term.erase(@source_cache_key)
    System.put_env("GITHUB_TOKEN", "preflight-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    AuthPreflight.invalidate(:test_setup)

    # A `default_request_fun` probe here asserts the transport outcome (a 401
    # clearing the memo). `/issues/{n}` reads are now cacheable (`:issue`,
    # #2352), and the read cache is a shared application child, so clear it so
    # the probe reaches the transport rather than a deposit from an earlier
    # test in the same partition.
    ReadCache.reset()

    on_exit(fn ->
      AuthPreflight.invalidate(:test_teardown)
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end

      case prev_source do
        :unset -> :persistent_term.erase(@source_cache_key)
        source -> :persistent_term.put(@source_cache_key, source)
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
    Aiur.TestSupport.refute_leak(diagnostic, "preflight-token")
  end

  test "a keyring-sourced credential is reported as the gh keyring, not GITHUB_TOKEN" do
    # Simulate a boot where `gh auth login` was the only credential: resolve_pat_token
    # cached the keyring token, so the diagnostic must name that source and give the
    # matching recovery, never "refresh or unset GITHUB_TOKEN" — a variable the
    # developer never set (#2374).
    :persistent_term.put(@token_cache_key, "keyring-token")
    :persistent_term.put(@source_cache_key, :keyring)

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

    assert diagnostic.token_source == "gh keyring"
    assert diagnostic.message =~ "gh keyring"
    assert diagnostic.message =~ "gh auth login"
    refute diagnostic.message =~ "refresh or unset GITHUB_TOKEN"
  end

  test "formats diagnostic maps and plain fallback reasons" do
    reason = {:github_auth_preflight_failed, %{message: "friendly"}}

    assert AuthPreflight.format_auth_preflight_error(reason) == "friendly"
    assert AuthPreflight.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
  end

  # #2429 F3 acceptance: a local budget hold during the preflight is a local
  # counter trip, not an App or credential problem. The message must name the
  # hold and point at the budget config — and must not emit the generic
  # recovery guidance (App reinstallation / GITHUB_TOKEN rotation), which could
  # never fix a local hold. `local_hold_message` short-circuits before the
  # token-source branch, so this holds for both GITHUB_APP and GITHUB_TOKEN
  # sources; pre-fix this diagnostic classified as `:transport` and carried the
  # wrong recovery text.
  #
  # The reset is 30s out — within the hold wait-out ceiling — so this also
  # exercises the re-armed cap (#2444): the request_fun keeps re-issuing the
  # same hold, preflight waits `@local_hold_max_waits` times (each sleep
  # injected to return immediately), and the final diagnostic still names the
  # hold.
  test "a local budget hold during preflight names the local hold, never App or token recovery" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    request_fun = fn _request -> {:error, {:aiur, :locally_held, hold}} end

    assert {:error, {:github_auth_preflight_failed, diagnostic}} =
             AuthPreflight.preflight_auth(
               request_fun: request_fun,
               gh_auth_status_fun: fn -> {:ok, :available} end,
               local_hold_sleep_fun: fn _ms -> :ok end
             )

    assert diagnostic.classification == :local_hold
    assert diagnostic.message =~ "local budget hold"
    assert diagnostic.message =~ "tracker.github.*_limit_per_hour"
    refute diagnostic.message =~ "verify the App is installed"
    refute diagnostic.message =~ "re-acquires a fresh installation token"
    refute diagnostic.message =~ "Recovery: refresh or unset GITHUB_TOKEN"
    refute diagnostic.message =~ "the request failed before GitHub returned a status"
  end

  # #2638: a 404 under App auth while GITHUB_TOKEN is also set is the
  # signature of a machine-wide App outranking the token an operator configured
  # for this repository. "Install the App" alone sends them the wrong way.
  test "an App 404 with GITHUB_TOKEN also set names the App-over-token precedence" do
    diagnostic = %{
      endpoint: :repo,
      repo: "owner/repo",
      token_source: "GITHUB_APP",
      reason: :repo_not_accessible,
      status: 404
    }

    System.put_env("GITHUB_TOKEN", "preflight-token")
    message = AuthPreflight.diagnostic_message(diagnostic, :unknown)

    assert message =~ "verify the App is installed on owner/repo"
    assert message =~ "GITHUB_TOKEN is also set, but configured GitHub App credentials take precedence"
    assert message =~ "does not inherit App credentials from ~/.aiur/.env"
    refute message =~ "preflight-token"

    System.delete_env("GITHUB_TOKEN")
    assert AuthPreflight.diagnostic_message(diagnostic, :unknown) =~ "verify the App is installed"
    refute AuthPreflight.diagnostic_message(diagnostic, :unknown) =~ "GITHUB_TOKEN is also set"

    System.put_env("GITHUB_TOKEN", "preflight-token")
    unauthorized = %{diagnostic | reason: :invalid_or_expired_token, status: 401}
    refute AuthPreflight.diagnostic_message(unauthorized, :unknown) =~ "GITHUB_TOKEN is also set"
  end

  test "local_hold_reason?/1 recognizes a held preflight but not other failures" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.utc_now()}
    diagnostic = %{classification: :local_hold, endpoint: :rate_limit, repo: "owner/repo", token_source: "GITHUB_APP"}

    assert AuthPreflight.local_hold_reason?({:github_auth_preflight_failed, diagnostic})
    assert AuthPreflight.local_hold_reason?({:aiur, :locally_held, hold})
    refute AuthPreflight.local_hold_reason?({:github_auth_preflight_failed, %{classification: :dns}})
    refute AuthPreflight.local_hold_reason?(:missing_github_token)
  end
end
