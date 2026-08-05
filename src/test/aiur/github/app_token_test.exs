defmodule Aiur.GitHub.AppTokenTest do
  # async: false — the acquire/1 tests set the GITHUB_APP_* env vars, which are
  # process-global: while they are set, any concurrent test reading
  # GitHub.Config.token/0 would be switched onto the App path.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.AppToken

  @app_id "12345"
  @installation_id "67890"

  defp jwk, do: JOSE.JWK.generate_key({:rsa, 2048})

  defp pem do
    {_map, pem} = JOSE.JWK.to_pem(jwk())
    pem
  end

  describe "app_jwt/3" do
    test "produces an RS256 JWT with the correct header, claims and signature" do
      now = DateTime.from_unix!(1_700_000_000)
      key = jwk()
      jwt = AppToken.app_jwt(key, @app_id, now)

      [header_b64, payload_b64, _sig] = String.split(jwt, ".")

      header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      payload = payload_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert header == %{"alg" => "RS256", "typ" => "JWT"}
      assert payload["iss"] == @app_id
      # iat is backdated 60s for clock skew (GitHub rejects a future iat), and
      # exp is anchored to iat so the window stays within GitHub's 10-minute
      # maximum rather than overshooting it by the skew allowance.
      assert payload["iat"] == 1_700_000_000 - 60
      assert payload["exp"] == payload["iat"] + 600
      assert payload["exp"] - payload["iat"] <= 600

      assert JOSE.JWT.verify_strict(key, ["RS256"], jwt) |> elem(0)
      refute JOSE.JWT.verify_strict(JOSE.JWK.generate_key({:rsa, 2048}), ["RS256"], jwt) |> elem(0)
    end
  end

  describe "exchange_token/3" do
    test "returns the parsed token, expiry and permissions on 200" do
      now = DateTime.from_unix!(1_700_000_000)
      jwt = AppToken.app_jwt(jwk(), @app_id, now)

      request_fun = fn %{method: :post, url: url, token: bearer} ->
        assert url == AppToken.access_tokens_url(@installation_id)
        # The caller's JWT must be what is sent as the bearer token, never a PAT.
        assert bearer == jwt
        assert String.split(bearer, ".") |> length() == 3

        {:ok,
         %{
           status: 200,
           body: %{
             "token" => "ghs_installation_token_123",
             "expires_at" => "2026-08-03T12:00:00Z",
             "permissions" => %{"contents" => "write", "metadata" => "read"}
           }
         }}
      end

      assert {:ok, %{token: "ghs_installation_token_123", expires_at: expires_at, permissions: permissions}} =
               AppToken.exchange_token(request_fun, jwt, @installation_id)

      assert DateTime.to_iso8601(expires_at) == "2026-08-03T12:00:00Z"
      assert permissions == %{"contents" => "write", "metadata" => "read"}
    end

    test "classifies an HTTP error into the github taxonomy" do
      request_fun = fn _request -> {:ok, %{status: 401, body: %{"message" => "bad jwt"}}} end

      assert {:error, {:github, :auth, %{status: 401}}} =
               AppToken.exchange_token(request_fun, "jwt-value", @installation_id)
    end

    test "classifies a rate-limited exchange" do
      request_fun = fn _request ->
        {:ok, %{status: 429, headers: %{"retry-after" => ["30"]}, body: %{}}}
      end

      assert {:error, {:github, :rate_limited, %{status: 429, retry_after: 30}}} =
               AppToken.exchange_token(request_fun, "jwt-value", @installation_id)
    end

    test "rejects a 2xx body missing the token/expiry" do
      request_fun = fn _request -> {:ok, %{status: 200, body: %{"permissions" => %{}}}} end

      assert {:error, :invalid_installation_token_response} =
               AppToken.exchange_token(request_fun, "jwt-value", @installation_id)
    end

    test "propagates a transport error" do
      request_fun = fn _request -> {:error, %Mint.TransportError{reason: :nxdomain}} end

      assert {:error, {:github, :dns, _detail}} =
               AppToken.exchange_token(request_fun, "jwt-value", @installation_id)
    end
  end

  describe "verify_permissions/1" do
    test "accepts exactly the least-privilege set" do
      assert :ok =
               AppToken.verify_permissions(%{
                 "contents" => "write",
                 "issues" => "write",
                 "pull_requests" => "write",
                 "metadata" => "read"
               })
    end

    test "flags Administration, Actions, Secrets and Workflows" do
      for extra <- ["administration", "actions", "secrets", "workflows"] do
        assert {:error, %{extra_permissions: %{^extra => "write"}}} =
                 AppToken.verify_permissions(%{"contents" => "write", extra => "write"})
      end
    end

    test "flags a permission elevated beyond the allowed level" do
      assert {:error, %{extra_permissions: %{"contents" => "read"}}} =
               AppToken.verify_permissions(%{"contents" => "read"})
    end

    # The posture forbids Organization permissions outright. They arrive in the
    # same flat `permissions` map as `organization_*` keys, and the check is an
    # allowlist rather than a denylist, so they are rejected without needing a
    # dedicated rule — pinned here so a future denylist rewrite cannot drop them.
    test "flags organization-level permissions" do
      for org_permission <- [
            "organization_administration",
            "organization_secrets",
            "organization_self_hosted_runners",
            "members"
          ] do
        assert {:error, %{extra_permissions: extra}} =
                 AppToken.verify_permissions(%{"contents" => "write", org_permission => "read"})

        assert Map.has_key?(extra, org_permission)
      end
    end
  end

  describe "refresh_delay_ms/3" do
    test "refreshes before expiry by the margin" do
      now = DateTime.from_unix!(1_700_000_000)
      # 30 min later
      expires_at = DateTime.from_unix!(1_700_001_800)

      assert AppToken.refresh_delay_ms(expires_at, now, margin_seconds: 300) == 1_500_000
    end

    test "floors an already-expiring token at the minimum interval" do
      now = DateTime.utc_now()

      assert AppToken.refresh_delay_ms(DateTime.add(now, 60), now) == 1_000
      assert AppToken.refresh_delay_ms(DateTime.add(now, -60), now) == 1_000
    end
  end

  describe "acquire/1" do
    test "runs the full pipeline and surfaces the permission violation" do
      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "token" => "ghs_installation_token_abc",
               "expires_at" => "2026-08-03T12:00:00Z",
               "permissions" => %{"contents" => "write", "administration" => "write"}
             }
           }}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      System.put_env("GITHUB_APP_ID", @app_id)
      System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)
      System.put_env("GITHUB_APP_PRIVATE_KEY", pem())

      on_exit(fn ->
        System.delete_env("GITHUB_APP_ID")
        System.delete_env("GITHUB_APP_INSTALLATION_ID")
        System.delete_env("GITHUB_APP_PRIVATE_KEY")
      end)

      assert {:ok,
              %{
                token: "ghs_installation_token_abc",
                permission_violation: %{extra_permissions: %{"administration" => "write"}}
              }} = AppToken.acquire(request_fun: request_fun)
    end

    test "rejects a rate-limit-exhausted installation token" do
      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "token" => "ghs_installation_token_abc",
               "expires_at" => "2026-08-03T12:00:00Z",
               "permissions" => %{"contents" => "write"}
             }
           }}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["0"]}, body: %{}}}
      end

      System.put_env("GITHUB_APP_ID", @app_id)
      System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)
      System.put_env("GITHUB_APP_PRIVATE_KEY", pem())

      on_exit(fn ->
        System.delete_env("GITHUB_APP_ID")
        System.delete_env("GITHUB_APP_INSTALLATION_ID")
        System.delete_env("GITHUB_APP_PRIVATE_KEY")
      end)

      assert {:error, :installation_token_rate_limited} = AppToken.acquire(request_fun: request_fun)
    end

    test "returns a clear error when the private key is missing" do
      System.delete_env("GITHUB_APP_PRIVATE_KEY")
      System.put_env("GITHUB_APP_ID", @app_id)
      System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)

      on_exit(fn ->
        System.delete_env("GITHUB_APP_ID")
        System.delete_env("GITHUB_APP_INSTALLATION_ID")
      end)

      assert {:error, :missing_private_key} = AppToken.acquire(request_fun: fn _ -> flunk("no request expected") end)
    end

    # An operator who pastes the App's *public* key supplies a PEM that decodes
    # and loads fine but cannot sign. acquire/1 must return an error tuple —
    # raising here would crash the refresher instead of alerting.
    test "returns an error, not a raise, for a valid-but-public-key PEM" do
      {_kty, public_pem} =
        JOSE.JWK.generate_key({:rsa, 2048})
        |> JOSE.JWK.to_public()
        |> JOSE.JWK.to_pem()

      System.put_env("GITHUB_APP_ID", @app_id)
      System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)
      System.put_env("GITHUB_APP_PRIVATE_KEY", public_pem)

      on_exit(fn ->
        System.delete_env("GITHUB_APP_ID")
        System.delete_env("GITHUB_APP_INSTALLATION_ID")
        System.delete_env("GITHUB_APP_PRIVATE_KEY")
      end)

      assert {:error, :invalid_private_key} =
               AppToken.acquire(request_fun: fn _ -> flunk("no request expected") end)
    end
  end
end
