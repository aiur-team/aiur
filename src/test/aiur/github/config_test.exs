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

  describe "keyring_token/1 — the gh auth token shell-out" do
    test "returns the stored token when gh answers promptly" do
      with_fake_gh_on_path(
        """
        if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
          printf 'ghs_keyring_only_token\\n'
          exit 0
        fi
        """,
        fn ->
          assert Config.keyring_token() == "ghs_keyring_only_token"
        end
      )
    end

    test "returns nil within the timeout when gh never returns, instead of hanging" do
      with_fake_gh_on_path(
        """
        if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
          while true; do sleep 1; done
        fi
        """,
        fn ->
          started = System.monotonic_time(:millisecond)
          assert Config.keyring_token(timeout_ms: 200) == nil
          elapsed = System.monotonic_time(:millisecond) - started

          # Completed promptly and treated the stall as "no keyring credential".
          assert elapsed < 5_000
        end
      )
    end

    test "logs before the shell-out so a hang is attributable" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              printf 'ghs_keyring_only_token\\n'
              exit 0
            fi
            """,
            fn ->
              assert Config.keyring_token(timeout_ms: 1_000) == "ghs_keyring_only_token"
            end
          )
        end)

      assert log =~ "github_keyring_lookup"
      assert log =~ "state=starting"
      assert log =~ "timeout_ms=1000"
    end

    test "logs a warning and returns nil when the shell-out times out" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              while true; do sleep 1; done
            fi
            """,
            fn ->
              assert Config.keyring_token(timeout_ms: 200) == nil
            end
          )
        end)

      assert log =~ "github_keyring_lookup"
      assert log =~ "state=timed_out"
      assert log =~ "gh auth login"
    end
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

  # Puts a fake `gh` on PATH for the duration of `fun` so the real
  # `System.cmd("gh", ...)` keyring shell-out resolves to a deterministic stub.
  # `token_script` must define the `gh auth token` behaviour and then fall
  # through: the helper appends a pass-through to the real `gh` (located before
  # PATH changed) for every other invocation, so a concurrent test that shells
  # out to `gh` still reaches the real binary instead of a stub.
  defp with_fake_gh_on_path(token_script, fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "aiur-config-fake-gh-#{unique}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    fake_gh = Path.join(bin_dir, "gh")

    pass_through =
      case System.find_executable("gh") do
        nil -> "exit 99\n"
        path -> "exec #{path} \"$@\"\n"
      end

    File.write!(fake_gh, "#!/bin/sh\n" <> token_script <> "\n" <> pass_through)
    File.chmod!(fake_gh, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    try do
      fun.()
    after
      case original_path do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end

      File.rm_rf!(root)
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
