defmodule Aiur.GitHub.AuthPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.Transport

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

    AuthPreflight.invalidate(:test_setup)

    on_exit(fn ->
      AuthPreflight.invalidate(:test_teardown)
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
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

  test "formats diagnostic maps and plain fallback reasons" do
    reason = {:github_auth_preflight_failed, %{message: "friendly"}}

    assert AuthPreflight.format_auth_preflight_error(reason) == "friendly"
    assert AuthPreflight.format_auth_preflight_error(:missing_github_token) == ":missing_github_token"
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
      AuthPreflight.note_response(%{method: :get, url: "https://api.github.com/repos/owner/repo/issues"}, {:ok, %{status: 401, headers: [], body: %{"message" => "Bad credentials"}}})

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

    test "a non-rate-limited 403 drops the memo, a rate-limited one does not" do
      opts = [request_fun: &ok_response/1, gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert AuthPreflight.memoized_identity()

      # A 403 carrying rate-limit headers is a quota problem, not an auth one.
      # Invalidating on it would buy three more requests per cycle at exactly
      # the moment the budget is exhausted.
      AuthPreflight.note_response(%{method: :get, url: "https://api.github.com/x"}, {:ok, %{status: 403, headers: [{"x-ratelimit-remaining", "0"}], body: %{"message" => "API rate limit exceeded"}}})

      assert AuthPreflight.memoized_identity()

      AuthPreflight.note_response(%{method: :get, url: "https://api.github.com/x"}, {:ok, %{status: 403, headers: [], body: %{"message" => "Resource not accessible"}}})

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
                 token: "revoked"
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
