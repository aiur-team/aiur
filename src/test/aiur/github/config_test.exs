defmodule Aiur.GitHub.ConfigTest do
  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  import Aiur.TestSupport,
    only: [
      write_workflow_file!: 2,
      write_workflow_file_atomic!: 2,
      ensure_workflow_store_running: 0
    ]

  alias Aiur.GitHub.Config
  alias Aiur.Workflow

  @cache_key {Config, :resolved_token}
  @origin_cache_key {Config, :resolved_origin_repo}
  @source_cache_key {Config, :resolved_token_source}

  setup do
    original = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      :persistent_term.erase(@cache_key)
      :persistent_term.erase(@source_cache_key)

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

  # One `~/.aiur/config` shared by daemons for several repositories can name at
  # most one repo, so identity has to resolve the repository the daemon is
  # actually polling — the checkout's origin — when the key carries no value.
  # Without that, every issue normalized to an unjoinable identity and every
  # dispatch failed `:missing_tracker_identity` (#2518).
  describe "configured_repo/1" do
    setup do
      # The active workflow file is a VM-global path every async: false module
      # shares, so restore the exact bytes this module found rather than a
      # hardcoded value that would leave a different repo behind for whatever
      # runs next.
      path = Workflow.workflow_file_path()
      original = File.read!(path)

      on_exit(fn ->
        write_workflow_file_atomic!(path, original)
        ensure_workflow_store_running()
        :ok = Aiur.WorkflowStore.force_reload(5_000)
        :persistent_term.erase(@origin_cache_key)
      end)

      :persistent_term.erase(@origin_cache_key)

      :ok
    end

    test "an explicitly configured repository is used without consulting the origin remote" do
      write_tracker_repo!("acme/widgets")

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(refuting_origin())
    end

    test "an omitted repository falls back to the checkout's origin remote" do
      write_tracker_repo!(nil)

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(origin("acme/widgets"))
    end

    test "a blank repository falls back to the checkout's origin remote" do
      write_tracker_repo!("   ")

      assert {:ok, {"acme", "widgets"}} = Config.configured_repo(origin("acme/widgets"))
    end

    test "an omitted repository with no origin remote stays explicitly missing" do
      write_tracker_repo!(nil)

      assert {:error, :missing_configured_repository} = Config.configured_repo(origin(nil))
    end

    test "a malformed configured repository stays fail-closed and never falls back" do
      write_tracker_repo!("owner/repo/extra")

      assert {:error, :invalid_configured_repository} = Config.configured_repo(refuting_origin())
    end

    # An auto-detected slug is not operator-typed, so it gets the same parse as
    # a configured one rather than being trusted into an identity.
    test "a malformed origin remote is rejected rather than trusted" do
      write_tracker_repo!(nil)

      assert {:error, :invalid_configured_repository} = Config.configured_repo(origin("not-a-slug"))
    end

    # The #2518 defect was `repo/0` and `configured_repo/0` disagreeing about
    # which repository this daemon is on. Pin the agreement against an injected
    # origin so the property holds regardless of the checkout the suite runs in.
    test "configured_repo/0 and repo/0 resolve the same repository when the key is omitted" do
      write_tracker_repo!(nil)

      assert Config.repo(origin("acme/widgets")) == "acme/widgets"
      assert Config.configured_repo(origin("acme/widgets")) == {:ok, {"acme", "widgets"}}
    end

    test "configured_repo/0 and repo/0 resolve the same repository when the key is set" do
      write_tracker_repo!("  acme/widgets  ")

      assert Config.repo(refuting_origin()) == "acme/widgets"
      assert Config.configured_repo(refuting_origin()) == {:ok, {"acme", "widgets"}}
    end

    test "repo/0 falls back to the origin remote for a blank key, like configured_repo/0" do
      write_tracker_repo!("   ")

      assert Config.repo(origin("acme/widgets")) == "acme/widgets"
      assert Config.repo(origin(nil)) == nil
    end

    # #2518 cost two investigations and a recommendation to edit a healthy live
    # config, because the failure named no file: the operator read a repo-local
    # `.aiur/config` while the failing daemon read the global one. The
    # diagnostic must name the file that was read AND the paths searched, or the
    # next reader repeats the mistake.
    test "the resolution diagnostic names the config file read and every path searched" do
      write_tracker_repo!(nil)

      diagnostic = Config.repository_resolution_diagnostic()

      assert diagnostic =~ "config_read=#{Workflow.workflow_file_path()}"
      assert diagnostic =~ "tracker.github.repo=unset"

      # Every candidate, so a reader can see the repo-local path was searched
      # even when the global file is the one that won.
      for candidate <- Workflow.config_path_candidates() do
        assert diagnostic =~ candidate,
               "diagnostic must name searched path #{candidate}, got: #{diagnostic}"
      end

      assert Enum.any?(Workflow.config_path_candidates(), &String.ends_with?(&1, "/.aiur/config")),
             "the searched set must include the repo-local and global .aiur/config paths"
    end

    test "the resolution diagnostic reports a configured repository as the value read" do
      write_tracker_repo!("acme/widgets")

      assert Config.repository_resolution_diagnostic() =~ "tracker.github.repo=acme/widgets"
    end

    # `explicit_configured_repo/0` is what durable on-disk scoping reads, so it
    # must never take the fallback — see `Aiur.IssueLog.configured_repository_scope/0`.
    test "explicit_configured_repo/0 never falls back to the origin remote" do
      write_tracker_repo!(nil)

      assert {:error, :missing_configured_repository} = Config.explicit_configured_repo()

      write_tracker_repo!("acme/widgets")

      assert {:ok, {"acme", "widgets"}} = Config.explicit_configured_repo()
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

  defp write_tracker_repo!(repo) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: repo)
  end

  defp origin(repo), do: [origin_fun: fn -> repo end]

  defp refuting_origin do
    [origin_fun: fn -> flunk("origin remote must not be consulted") end]
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
