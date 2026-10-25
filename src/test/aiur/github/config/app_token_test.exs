defmodule Aiur.GitHub.Config.AppTokenTest do
  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config

  @cache_key {Aiur.GitHub.Access.Token, :resolved_token}
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"
  @source_cache_key {Aiur.GitHub.Access.Token, :resolved_token_source}

  setup do
    original = System.get_env("GITHUB_TOKEN")
    original_keyring_timeout = System.get_env(@keyring_timeout_env)

    on_exit(fn ->
      :persistent_term.erase(@cache_key)
      :persistent_term.erase(@source_cache_key)

      case original do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end

      case original_keyring_timeout do
        nil -> System.delete_env(@keyring_timeout_env)
        value -> System.put_env(@keyring_timeout_env, value)
      end
    end)

    :ok
  end

  describe "GitHub App installation-token integration" do
    alias Aiur.GitHub.AppTokenRefresher

    @app_env_keys [
      "GITHUB_APP_ID",
      "GITHUB_APP_INSTALLATION_ID",
      "GITHUB_APP_PRIVATE_KEY",
      "GITHUB_APP_PRIVATE_KEY_PATH"
    ]

    @hosted_auth_env_keys ["AIUR_SECRETS_FROM_ENV", "AIUR_STATE_PERSISTENT", "AIUR_GITHUB_ALLOW_PAT"]

    defp put_app_credentials do
      {_jwk, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
      System.put_env("GITHUB_APP_ID", "12345")
      System.put_env("GITHUB_APP_INSTALLATION_ID", "67890")
      System.put_env("GITHUB_APP_PRIVATE_KEY", pem)
    end

    setup do
      previous = Map.new(@app_env_keys ++ @hosted_auth_env_keys, fn key -> {key, System.get_env(key)} end)

      on_exit(fn ->
        Enum.each(@app_env_keys ++ @hosted_auth_env_keys, fn key ->
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
        DateTime.add(DateTime.utc_now(), 3_600, :second),
        %{"contents" => "write"}
      )

      assert Config.token() == "ghs_installation_token"
    end

    test "regression guard: hosted token resolution keeps App priority when PAT is also set" do
      put_app_credentials()
      System.put_env("GITHUB_TOKEN", "personal-access-token")
      System.put_env("AIUR_SECRETS_FROM_ENV", "1")
      System.delete_env("AIUR_STATE_PERSISTENT")
      System.delete_env("AIUR_GITHUB_ALLOW_PAT")

      AppTokenRefresher.cache_token(
        "ghs_installation_token",
        DateTime.add(DateTime.utc_now(), 3_600, :second),
        %{"contents" => "write"}
      )

      assert Config.token() == "ghs_installation_token"
      assert Config.token_source() == :github_app
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

    test "hosted auth refuses a PAT unless the PAT opt-in is enabled" do
      previous = Map.new(@app_env_keys, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      Enum.each(@app_env_keys, &System.delete_env/1)
      System.put_env("GITHUB_TOKEN", "hosted-pat")

      assert Config.resolve_token(
               hosted?: true,
               pat_opted_in?: false,
               validate_fun: fn _token -> true end,
               keyring_fun: fn -> flunk("hosted auth must not consult the keyring") end
             ) == nil

      assert Config.resolve_token(hosted?: true, pat_opted_in?: true, validate_fun: fn _token -> true end, keyring_fun: fn -> flunk("explicit hosted PAT does not need the keyring") end) ==
               "hosted-pat"
    end

    test "validate!/0 names the App credentials when configured but the token is unavailable" do
      put_app_credentials()

      assert {:error, message} = Config.validate!()
      assert message =~ "GITHUB_APP_ID"
      assert message =~ "installation"
      refute message =~ "GITHUB_TOKEN"
    end
  end
end
