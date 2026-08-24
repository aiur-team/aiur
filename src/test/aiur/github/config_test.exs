defmodule Aiur.GitHub.ConfigTest do
  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config

  @cache_key {Config, :resolved_token}
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"

  setup do
    original = System.get_env("GITHUB_TOKEN")
    original_keyring_timeout = System.get_env(@keyring_timeout_env)

    on_exit(fn ->
      :persistent_term.erase(@cache_key)

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
        end,
        assert_reaped: true
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
            end,
            assert_reaped: true
          )
        end)

      assert log =~ "github_keyring_lookup"
      assert log =~ "state=timed_out"
      assert log =~ "gh auth login"
    end

    test "returns nil when no gh resolves on PATH (the missing-binary degradation)" do
      # A box with no gh at all: HostCommand.find_executable/1 resolves nothing
      # and the runner returns {"", 127}, which keyring_token/1 treats exactly
      # like a failed lookup — nil — so the boot gate can raise its normal
      # missing-credential message. This is the {"", 127} degradation path, not
      # an :enoent raise: HostCommand guards its System.cmd call, so a gh-less
      # PATH never reaches the raising path. The raising path is covered
      # separately by the injected-runner test below.
      with_empty_path(fn ->
        assert Config.keyring_token(timeout_ms: 1_000) == nil
      end)
    end

    test "a runner that raises degrades to nil instead of killing the caller" do
      # Review blocker: Task.async links the shell-out task to the caller, so an
      # uncaught exception inside the task exits it abnormally and the link
      # kills the caller before Task.yield ever returns. The rescue lives inside
      # the task and turns any runner failure into "no keyring credential".
      # The :run_fun seam drives a runner that actually raises, making that
      # rescue load-bearing — without the seam, the rescue was untestable
      # because HostCommand.run degrades a missing binary to {"", 127} before
      # System.cmd can raise :enoent.
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> raise "boom" end) == nil
    end

    test "a runner that throws or exits degrades to nil instead of killing the caller" do
      # The in-task guard is `catch _, _ -> nil` as well as `rescue _ -> nil`:
      # rescue alone only covers raises, so a `throw` or `exit` from run_fun
      # would exit the linked task abnormally and kill the caller across the
      # link by the same path as an uncaught raise. Both must degrade to "no
      # keyring credential" instead.
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> throw(:boom) end) == nil
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> exit(:boom) end) == nil
    end

    test "a stalled gh and the process it spawned are killed together on timeout" do
      # Review blocker: the timeout kill must target the whole process GROUP,
      # not just the direct child. On a host where the guard wrapper
      # (~/.aiur/bin/gh) is the port program, the direct pid is the wrapper
      # shell and the real `gh` runs as its child — a single-pid kill would
      # orphan it, still holding the locked keyring. The BEAM's port spawn
      # makes the direct child a group leader (os_pid == pgid), so a
      # negative-pid kill reaches the wrapper AND everything it spawned. This
      # test drives the real shell-out against a never-returning fake gh that
      # spawns a grandchild and records both pids, then asserts neither is live
      # after the lookup returns — the grandchild dying is what makes the group
      # kill distinguishable from a direct-pid kill.
      root = Aiur.TestSupport.tmp_root!("aiur-config-keyring-orphan")
      File.mkdir_p!(root)
      pidfile = Path.join(root, "gh.pid")
      childfile = Path.join(root, "gh.child.pid")

      try do
        with_fake_gh_on_path(
          """
          if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
            echo $$ > #{pidfile}
            sleep 300 &
            echo $! > #{childfile}
            while true; do sleep 1; done
          fi
          """,
          fn ->
            assert Config.keyring_token(timeout_ms: 200) == nil
            assert File.exists?(pidfile), "the fake gh never started"
            assert File.exists?(childfile), "the fake gh never spawned its child"

            pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()
            child = childfile |> File.read!() |> String.trim() |> String.to_integer()

            # Allow the kill and reap to land, then assert neither the fake gh
            # nor its spawned child is a live process (a reaped pid or a zombie
            # both count dead).
            Process.sleep(200)
            refute live_process?(pid), "gh pid #{pid} survived the timeout"
            refute live_process?(child), "gh child pid #{child} survived the timeout"
          end
        )
      after
        File.rm_rf!(root)
      end
    end

    test "the shipped default timeout is bounded so a boot stall cannot ship unnoticed" do
      # Pins @keyring_command_timeout_ms in the safe direction: every other test
      # injects its own timeout_ms or pins the env override, so a mutation to a
      # ten-minute stall would otherwise leave the whole suite green while boot
      # hangs. Boot must fail fast on a locked keyring.
      System.delete_env(@keyring_timeout_env)

      timeout = Config.keyring_command_timeout_ms()
      assert is_integer(timeout)
      assert timeout >= 1
      assert timeout <= 10_000
    end

    test "AIUR_GH_KEYRING_TIMEOUT_MS overrides the default timeout" do
      System.put_env(@keyring_timeout_env, "7000")

      assert Config.keyring_timeout_ms() == 7_000
      assert Config.keyring_timeout_ms(timeout_ms: 1_000) == 1_000
    end

    test "an invalid AIUR_GH_KEYRING_TIMEOUT_MS falls back to the compiled default" do
      for bad <- ["banana", "0", "-5", ""] do
        System.put_env(@keyring_timeout_env, bad)
        assert Config.keyring_timeout_ms() == Config.keyring_command_timeout_ms()
      end
    end

    test "the env override is applied to the real shell-out" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              printf 'ghs_env_override\\n'
              exit 0
            fi
            """,
            fn ->
              System.put_env(@keyring_timeout_env, "900")
              assert Config.keyring_token() == "ghs_env_override"
            end
          )
        end)

      assert log =~ "timeout_ms=900"
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
  #
  # `assert_reaped: true` makes the fake `gh` record its OS pid and registers an
  # `on_exit` that fails the test if that pid is still live after the test
  # completes — the CI-hang guard from the review. A leaked never-returning
  # fake `gh` (the very process this ticket bounds) surfaces as a fast
  # assertion failure instead of a stalled ExUnit shard holding a pipe open.
  defp with_fake_gh_on_path(token_script, fun, opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "aiur-config-fake-gh-#{unique}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    fake_gh = Path.join(bin_dir, "gh")

    {pidfile, script} = fake_gh_script(token_script, unique, opts)
    pass_through = pass_through_script()

    File.write!(fake_gh, "#!/bin/sh\n" <> script <> "\n" <> pass_through)
    File.chmod!(fake_gh, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    if pidfile, do: assert_reaped_on_exit(pidfile, "fake gh")

    try do
      fun.()
    after
      restore_path(original_path)
      File.rm_rf!(root)
    end
  end

  # Builds the fake `gh` script: with `assert_reaped: true` the fake records
  # its OS pid to a file (in a directory outside the fake-gh root, which is
  # removed before `on_exit` runs) so `assert_reaped_on_exit/2` can assert the
  # process was killed rather than leaked. Returns `{pidfile_or_nil, script}`.
  defp fake_gh_script(token_script, unique, opts) do
    case Keyword.get(opts, :assert_reaped, false) do
      false ->
        {nil, token_script}

      true ->
        pid_root = Path.join(System.tmp_dir!(), "aiur-config-keyring-reap-#{unique}")
        File.mkdir_p!(pid_root)
        pidfile = Path.join(pid_root, "gh.pid")
        {pidfile, "echo $$ > #{pidfile}\n" <> token_script}
    end
  end

  defp pass_through_script do
    case System.find_executable("gh") do
      nil -> "exit 99\n"
      path -> "exec #{path} \"$@\"\n"
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)

  # Fails the test if the OS pid recorded at `pidfile` is still live when the
  # test completes, then removes the recording directory. Registered by
  # `with_fake_gh_on_path/3` with `assert_reaped: true` so a leaked
  # never-returning fake `gh` — the orphan a failed timeout-kill would leave
  # behind — is caught deterministically after the test body runs rather than
  # stalling the CI shard. The pidfile lives outside the fake-gh root because
  # that root is removed when the helper's `after` runs, before `on_exit`.
  defp assert_reaped_on_exit(pidfile, label) do
    on_exit(fn ->
      try do
        case File.read(pidfile) do
          {:ok, contents} ->
            pid = contents |> String.trim() |> String.to_integer()
            refute live_process?(pid), "#{label} pid #{pid} survived the test (leaked process)"

          _ ->
            :ok
        end
      after
        File.rm_rf!(Path.dirname(pidfile))
      end
    end)
  end

  defp authorization_token(opts) do
    opts
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn
      {"Authorization", "Bearer " <> token} -> token
      _ -> nil
    end)
  end

  # Sets PATH to a directory with no executables, so `gh` is genuinely absent
  # and the {"", 127} missing-binary degradation path is exercised — the box
  # with no gh installed at all. HostCommand.run guards its System.cmd call, so
  # this never reaches the raising `:enoent` path (that one is covered by the
  # injected-runner test).
  defp with_empty_path(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "aiur-config-empty-path-#{unique}")
    File.mkdir_p!(root)

    original_path = System.get_env("PATH")
    System.put_env("PATH", root)

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

  # True when `pid` names a live (non-zombie) process. A process killed by
  # SIGKILL either disappears or lingers as a zombie (`ps` stat "Z") until its
  # parent reaps it; neither is a live process, so only an empty/absent stat or
  # a "Z" stat counts as dead.
  defp live_process?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("sh", ["-c", "ps -o stat= -p #{pid} 2>/dev/null"]) do
      {out, 0} ->
        case String.trim(out) do
          "" -> false
          "Z" <> _ -> false
          _ -> true
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
