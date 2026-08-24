defmodule Aiur.GitHub.AuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.Transport

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

  defp counting_request_fun(counter, response_fun) do
    fn request ->
      Agent.update(counter, &(&1 + 1))
      response_fun.(request)
    end
  end

  defp start_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counter
  end

  defp count(counter), do: Agent.get(counter, & &1)

  defp ok_response(_request),
    do: {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}

  # An ordinary, non-preflight tracker request carrying the proven credential.
  defp request do
    %{method: :get, url: "https://api.github.com/repos/owner/repo/issues", token: "preflight-token"}
  end

  defp unauthorized,
    do: {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}

  defp put_or_delete(key, nil), do: Application.delete_env(:aiur, key)
  defp put_or_delete(key, value), do: Application.put_env(:aiur, key, value)

  defp put_token(token) do
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", token)
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
  test "a local budget hold during preflight names the local hold, never App or token recovery" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    request_fun = fn _request -> {:error, {:aiur, :locally_held, hold}} end

    assert {:error, {:github_auth_preflight_failed, diagnostic}} =
             AuthPreflight.preflight_auth(
               request_fun: request_fun,
               gh_auth_status_fun: fn -> {:ok, :available} end
             )

    assert diagnostic.classification == :local_hold
    assert diagnostic.message =~ "local budget hold"
    assert diagnostic.message =~ "tracker.github.*_limit_per_hour"
    refute diagnostic.message =~ "verify the App is installed"
    refute diagnostic.message =~ "re-acquires a fresh installation token"
    refute diagnostic.message =~ "Recovery: refresh or unset GITHUB_TOKEN"
    refute diagnostic.message =~ "the request failed before GitHub returned a status"
  end

  test "local_hold_reason?/1 recognizes a held preflight but not other failures" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.utc_now()}
    diagnostic = %{classification: :local_hold, endpoint: :rate_limit, repo: "owner/repo", token_source: "GITHUB_APP"}

    assert AuthPreflight.local_hold_reason?({:github_auth_preflight_failed, diagnostic})
    assert AuthPreflight.local_hold_reason?({:aiur, :locally_held, hold})
    refute AuthPreflight.local_hold_reason?({:github_auth_preflight_failed, %{classification: :dns}})
    refute AuthPreflight.local_hold_reason?(:missing_github_token)
  end

  describe "ensure_preflight/1 — what an idle hour costs" do
    test "six idle poll cycles spend three requests in total, not eighteen" do
      counter = start_counter()
      opts = [request_fun: counting_request_fun(counter, &ok_response/1), gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      # Six cycles is one hour at the shipped idle cadence:
      # polling.interval_seconds 120 * polling.idle_widen_factor 5.0 = 600s.
      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert count(counter) == 3

      for _cycle <- 2..6 do
        assert :ok = AuthPreflight.ensure_preflight(opts)
      end

      # 3 requests for the whole hour, of which /rate_limit is unbilled:
      # 2 billed for the hour rather than 12.
      assert count(counter) == 3
    end

    test "the unmemoized preflight_auth/1 still pays every time" do
      counter = start_counter()
      opts = [request_fun: counting_request_fun(counter, &ok_response/1), gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.preflight_auth(opts)
      assert :ok = AuthPreflight.preflight_auth(opts)

      assert count(counter) == 6
    end

    test "a failed check is never memoized, so a broken credential is re-checked every cycle" do
      counter = start_counter()

      opts = [
        request_fun: counting_request_fun(counter, fn _ -> {:ok, %{status: 401, headers: [], body: %{}}} end),
        gh_auth_status_fun: fn -> {:ok, :not_installed} end
      ]

      assert {:error, {:github_auth_preflight_failed, _}} = AuthPreflight.ensure_preflight(opts)
      assert {:error, {:github_auth_preflight_failed, _}} = AuthPreflight.ensure_preflight(opts)

      assert count(counter) == 2
      refute AuthPreflight.memoized_identity()
    end
  end

  describe "ensure_preflight/1 — proving it still fails closed" do
    test "a token revoked mid-run produces the full diagnostic on the next cycle" do
      # Cycle 1: credentials are good and the answer is memoized.
      counter = start_counter()

      assert :ok =
               AuthPreflight.ensure_preflight(
                 request_fun: counting_request_fun(counter, &ok_response/1),
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert count(counter) == 3

      # Mid-run, an ordinary (non-preflight) GitHub call comes back 401 — this
      # is what `Aiur.GitHub.Transport` reports for every request it issues.
      AuthPreflight.note_response(request(), unauthorized())

      refute AuthPreflight.memoized_identity()

      # Cycle 2 pays for the full check and raises the ordinary diagnostic
      # rather than letting a raw 401 escape downstream.
      revoked_counter = start_counter()

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               AuthPreflight.ensure_preflight(
                 request_fun:
                   counting_request_fun(revoked_counter, fn _ ->
                     {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}}
                   end),
                 gh_auth_status_fun: fn -> {:ok, :available} end
               )

      assert count(revoked_counter) == 1
      assert diagnostic.reason == :invalid_or_expired_token
      assert diagnostic.status == 401
      assert diagnostic.message =~ "GITHUB_TOKEN"
      refute inspect(diagnostic) =~ "preflight-token"
    end

    # No 403 invalidates. A rate-limit 403 is a quota problem and a permission
    # 403 is a scope problem; in both cases the preflight itself still returns
    # `:ok`, so dropping the memo would erase, re-prove and erase forever —
    # three requests a cycle, permanently, and never converging.
    test "no 403 drops the memo, because re-proving one would never converge" do
      opts = [request_fun: &ok_response/1, gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert AuthPreflight.memoized_identity()

      for body <- [%{"message" => "API rate limit exceeded"}, %{"message" => "Resource not accessible by integration"}] do
        AuthPreflight.note_response(request(), {:ok, %{status: 403, headers: [], body: body}})
        assert AuthPreflight.memoized_identity()
      end
    end

    # The App JWT that mints installation tokens is not the tracker credential.
    # A 401 on it says nothing about the one that was proven.
    test "a 401 carrying a different credential leaves the memo alone" do
      opts = [request_fun: &ok_response/1, gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)

      AuthPreflight.note_response(Map.put(request(), :token, "some-other-credential"), unauthorized())

      assert AuthPreflight.memoized_identity()

      AuthPreflight.note_response(Map.put(request(), :token, "preflight-token"), unauthorized())

      refute AuthPreflight.memoized_identity()
    end

    # The window the invalidation epoch exists to close: the memo is empty while
    # the three checks are in flight, so a 401 arriving then finds nothing to
    # erase. Without the epoch, the `:ok` that was true when it was issued would
    # re-bless a credential that has since died, and nothing would notice until
    # the next real 401.
    test "a revocation during the check is not overwritten by the result of that check" do
      revoke_midflight = fn request ->
        if String.ends_with?(request.url, "/issues?state=open&per_page=1") do
          AuthPreflight.note_response(request(), unauthorized())
        end

        ok_response(request)
      end

      assert :ok =
               AuthPreflight.ensure_preflight(
                 request_fun: revoke_midflight,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      refute AuthPreflight.memoized_identity()
    end

    test "the preflight's own responses never invalidate the memo it is filling" do
      opts = [request_fun: &ok_response/1, gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)

      AuthPreflight.note_response(%{preflight?: true, url: "https://api.github.com/rate_limit"}, {:ok, %{status: 401, headers: [], body: %{}}})

      assert AuthPreflight.memoized_identity()
    end

    test "a rotated token is a different credential, so it is proven again" do
      counter = start_counter()
      opts = [request_fun: counting_request_fun(counter, &ok_response/1), gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert count(counter) == 3

      first_identity = AuthPreflight.memoized_identity()

      put_token("rotated-preflight-token")

      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert count(counter) == 6
      refute AuthPreflight.memoized_identity() == first_identity
    end

    test "a real 401 through Transport drops the memo, with nothing mocked in between" do
      # The other tests call `note_response/2` directly, so they would all keep
      # passing if `Transport` stopped reporting. This one goes through the
      # actual request path.
      {:ok, _started} = Application.ensure_all_started(:req)

      previous_options = Application.get_env(:aiur, :github_transport_test_options)
      previous_quota = Application.get_env(:aiur, :github_quota_server)
      previous_budget = Application.get_env(:aiur, :github_budget_enabled?)

      quota = start_supervised!({Quota, name: nil, emit_fun: fn _name, _opts -> :ok end})
      Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
      Application.put_env(:aiur, :github_quota_server, quota)
      Application.put_env(:aiur, :github_budget_enabled?, false)

      on_exit(fn ->
        put_or_delete(:github_transport_test_options, previous_options)
        put_or_delete(:github_quota_server, previous_quota)
        put_or_delete(:github_budget_enabled?, previous_budget)
      end)

      assert :ok =
               AuthPreflight.ensure_preflight(
                 request_fun: &ok_response/1,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end
               )

      assert AuthPreflight.memoized_identity()

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:ok, %{status: 401}} =
               Transport.default_request_fun(%{
                 method: :get,
                 url: "https://api.github.com/repos/owner/repo/issues/1",
                 token: "preflight-token"
               })

      refute AuthPreflight.memoized_identity()
    end

    test "the memo holds a digest, never the token itself" do
      opts = [request_fun: &ok_response/1, gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)

      refute inspect(AuthPreflight.memoized_identity()) =~ "preflight-token"
    end
  end
end
