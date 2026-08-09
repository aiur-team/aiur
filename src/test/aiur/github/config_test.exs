defmodule Aiur.GitHub.ConfigTest do
  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config

  @cache_key {Config, :resolved_token}

  setup do
    original = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      :persistent_term.erase(@cache_key)

      case original do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end
    end)

    :ok
  end

  # Why precedence matters: aiur-engine.sh sources GITHUB_TOKEN from .env, which
  # can go stale, while the live token lives in gh's keyring. resolve_token/1 must
  # prefer a *valid* env token but fall back to the keyring when env is invalid,
  # so the daemon's GitHub polls don't 404/401 on a stale .env token (#578).

  test "valid env token -> returns the env token" do
    System.put_env("GITHUB_TOKEN", "env-token")

    resolved =
      Config.resolve_token(
        validate_fun: fn token -> token == "env-token" end,
        keyring_fun: fn -> "keyring-token" end
      )

    assert resolved == "env-token"
  end

  test "invalid env token + valid keyring -> returns the keyring token" do
    System.put_env("GITHUB_TOKEN", "stale-env-token")

    resolved =
      Config.resolve_token(
        validate_fun: fn token -> token == "keyring-token" end,
        keyring_fun: fn -> "keyring-token" end
      )

    assert resolved == "keyring-token"
  end

  test "rate-exhausted env token + valid keyring -> returns the keyring token" do
    System.put_env("GITHUB_TOKEN", "rate-exhausted-env-token")

    request_fun = fn _url, opts ->
      token = authorization_token(opts)

      case token do
        "rate-exhausted-env-token" ->
          {:ok,
           %{
             status: 200,
             headers: %{"x-ratelimit-remaining" => ["0"]},
             body: %{"resources" => %{"core" => %{"remaining" => 0}}}
           }}

        "keyring-token" ->
          {:ok,
           %{
             status: 200,
             headers: %{"x-ratelimit-remaining" => ["42"]},
             body: %{"resources" => %{"core" => %{"remaining" => 42}}}
           }}
      end
    end

    resolved =
      Config.resolve_token(
        request_fun: request_fun,
        keyring_fun: fn -> "keyring-token" end
      )

    assert resolved == "keyring-token"
    assert Config.token() == "keyring-token"
  end

  test "invalid env + invalid keyring -> returns the env token as last resort" do
    System.put_env("GITHUB_TOKEN", "stale-env-token")

    resolved =
      Config.resolve_token(
        validate_fun: fn _token -> false end,
        keyring_fun: fn -> "also-stale-keyring" end
      )

    assert resolved == "stale-env-token"
  end

  test "absent env + valid keyring -> returns the keyring token" do
    System.delete_env("GITHUB_TOKEN")

    resolved =
      Config.resolve_token(
        validate_fun: fn token -> token == "keyring-token" end,
        keyring_fun: fn -> "keyring-token" end
      )

    assert resolved == "keyring-token"
  end

  test "token/0 returns the resolved value after resolve_token" do
    System.put_env("GITHUB_TOKEN", "stale-env-token")

    Config.resolve_token(
      validate_fun: fn token -> token == "keyring-token" end,
      keyring_fun: fn -> "keyring-token" end
    )

    assert Config.token() == "keyring-token"
  end

  test "token/0 falls back to the raw GITHUB_TOKEN env when unresolved" do
    :persistent_term.erase(@cache_key)
    System.put_env("GITHUB_TOKEN", "raw-env-token")

    assert Config.token() == "raw-env-token"
  end

  test "human merger allowlist is explicit and case-insensitive" do
    allowed = ["its-everdred"]

    assert Config.human_merger_allowed?("ITS-EVERDRED", allowed)
    refute Config.human_merger_allowed?("its-applekid", allowed)
    refute Config.human_merger_allowed?(nil, allowed)
    refute Config.human_merger_allowed?("its-everdred", [])
  end

  describe "GitHub App installation-token integration" do
    alias Aiur.GitHub.AppTokenRefresher

    @app_env_keys [
      "GITHUB_APP_ID",
      "GITHUB_APP_INSTALLATION_ID",
      "GITHUB_APP_PRIVATE_KEY",
      "GITHUB_APP_PRIVATE_KEY_PATH"
    ]

    defp put_app_credentials do
      {_jwk, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
      System.put_env("GITHUB_APP_ID", "12345")
      System.put_env("GITHUB_APP_INSTALLATION_ID", "67890")
      System.put_env("GITHUB_APP_PRIVATE_KEY", pem)
    end

    setup do
      previous = Map.new(@app_env_keys, fn key -> {key, System.get_env(key)} end)

      on_exit(fn ->
        Enum.each(@app_env_keys, fn key ->
          case Map.fetch!(previous, key) do
            nil -> System.delete_env(key)
            value -> System.put_env(key, value)
          end
        end)

        AppTokenRefresher.clear_token()
      end)

      :ok
    end

    test "token/0 serves the cached installation token when App credentials are configured" do
      put_app_credentials()

      AppTokenRefresher.cache_token(
        "ghs_installation_token",
        DateTime.from_iso8601("2026-08-03T12:00:00Z") |> elem(1),
        %{"contents" => "write"}
      )

      assert Config.token() == "ghs_installation_token"
    end

    test "token/0 returns nil when App credentials are configured but no token is cached" do
      put_app_credentials()
      AppTokenRefresher.clear_token()

      assert Config.token() == nil
    end

    test "resolve_token/1 acquires, caches and returns the installation token" do
      put_app_credentials()

      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "token" => "ghs_installation_token_boot",
               "expires_at" => "2026-08-03T12:00:00Z",
               "permissions" => %{"contents" => "write", "metadata" => "read"}
             }
           }}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      assert Config.resolve_token(request_fun: request_fun) == "ghs_installation_token_boot"
      assert Config.token() == "ghs_installation_token_boot"
    end

    test "resolve_token/1 returns nil without raising when acquisition fails" do
      put_app_credentials()

      request_fun = fn _request -> {:ok, %{status: 500, body: %{}}} end

      assert Config.resolve_token(request_fun: request_fun) == nil
      assert Config.token() == nil
    end

    test "validate!/0 names the App credentials when configured but the token is unavailable" do
      put_app_credentials()

      assert {:error, message} = Config.validate!()
      assert message =~ "GITHUB_APP_ID"
      assert message =~ "installation"
      refute message =~ "GITHUB_TOKEN"
    end
  end

  defp authorization_token(opts) do
    opts
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn
      {"Authorization", "Bearer " <> token} -> token
      _ -> nil
    end)
  end
end
