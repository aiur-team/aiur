defmodule Aiur.GitHub.ConfigTest do
  import Aiur.GitHub.Config.TestFixtures

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

  test "token_source/0 reports the env var when GITHUB_TOKEN is set and unresolved" do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@source_cache_key)
    System.put_env("GITHUB_TOKEN", "raw-env-token")

    assert Config.token_source() == :env
  end

  test "token_source/0 reports the keyring when resolve_token fell back to it" do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@source_cache_key)
    System.delete_env("GITHUB_TOKEN")

    assert Config.resolve_token(
             validate_fun: fn token -> token == "keyring-token" end,
             keyring_fun: fn -> "keyring-token" end
           ) == "keyring-token"

    assert Config.token_source() == :keyring
  end

  test "token_source/0 reports the env var when resolve_token used it" do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@source_cache_key)
    System.put_env("GITHUB_TOKEN", "env-token")

    assert Config.resolve_token(
             validate_fun: fn token -> token == "env-token" end,
             keyring_fun: fn -> "keyring-token" end
           ) == "env-token"

    assert Config.token_source() == :env
  end

  test "token_source/0 reports :none when no credential is resolved or present" do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@source_cache_key)
    System.delete_env("GITHUB_TOKEN")

    assert Config.token_source() == :none
  end

  test "keyring_token/0 returns nil or a token string without raising" do
    # The host may or may not be logged into the gh keyring, so only the
    # stable contract is asserted: a token string or nil, never a raise.
    assert (result = Config.keyring_token()) == nil or is_binary(result)
  end

  test "human merger allowlist is explicit and case-insensitive" do
    allowed = ["its-everdred"]

    assert Config.human_merger_allowed?("ITS-EVERDRED", allowed)
    refute Config.human_merger_allowed?("its-applekid", allowed)
    refute Config.human_merger_allowed?(nil, allowed)
    refute Config.human_merger_allowed?("its-everdred", [])
  end
end
