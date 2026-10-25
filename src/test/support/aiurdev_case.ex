defmodule Aiur.TestSupport.AiurdevCase do
  @moduledoc false
  # Shared fixtures for the scripts/aiurdev shim tests (ScriptsAiurdev*Test).

  import ExUnit.Callbacks, only: [on_exit: 1]

  @script Path.expand("../../../scripts/aiurdev", __DIR__)
  def script, do: @script

  # Shell fixtures in this module model ordinary machines where the temporary
  # directory is outside the agent workspace. The live workspace may set
  # TMPDIR beneath `aiur-workspaces`, which intentionally activates shim safety
  # behavior and changes those fixture semantics.
  def isolated_tmp_root do
    key = {__MODULE__, :isolated_tmp_root}

    case Process.get(key) || caller_tmp_root(key) do
      nil ->
        root = Path.join("/tmp", "aiur-test-tmp-#{System.pid()}-#{System.unique_integer([:positive])}")
        File.mkdir_p!(root)
        Process.put(key, root)
        on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
        root

      root ->
        Process.put(key, root)
        root
    end
  end

  defp caller_tmp_root(key) do
    Process.get(:"$callers", [])
    |> Enum.find_value(&tmp_root_for_process(&1, key))
  end

  defp tmp_root_for_process(pid, key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> dictionary_tmp_root(dictionary, key)
      nil -> nil
    end
  end

  defp dictionary_tmp_root(dictionary, key) do
    case List.keyfind(dictionary, key, 0) do
      {^key, root} -> root
      nil -> nil
    end
  end

  # The shim sources scripts/lib/aiurdev-*.sh next to itself, so copies need them.
  def copy_shim_libs!(dir), do: File.cp_r!(Path.join(Path.dirname(@script), "lib"), Path.join(dir, "lib"))

  # A fake repo root whose engine just echoes how the shim invoked it, so we can
  # assert on AIUR_RELEASE_DIR + forwarded args without building a real release.
  def fake_repo(root \\ nil) do
    root = root || Path.join(isolated_tmp_root(), "aiurdev-shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(isolated_tmp_root())
    libexec = Path.join([root, "packaging", "npm", "aiur-cli", "libexec"])
    File.mkdir_p!(libexec)
    # `--test` resets the sandbox from $repo_root/src; the dir must exist to cd into.
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/mix.lock"), "%{}\n")
    File.touch!(Path.join(root, "src/mix.lock"), {{2000, 1, 1}, {0, 0, 0}})
    browser = Path.join(root, "src/browser")
    File.mkdir_p!(browser)
    # chmod on the fake launcher rounds its mtime to seconds; seed inputs older.
    for file <- ["package.json", "package-lock.json"] do
      File.write!(Path.join(browser, file), "{}")
      File.touch!(Path.join(browser, file), {{2000, 1, 1}, {0, 0, 0}})
    end

    assets = Path.join(root, "src/priv/static/vendor/elk/0.11.1")
    File.mkdir_p!(assets)
    for file <- ["elk-worker.min.js", "aiur-layout-worker.js", "aiur-layout-client.js", "manifest.json"], do: File.write!(Path.join(assets, file), "fixture")
    File.touch!(Path.join(assets, "manifest.json"), {{2000, 1, 1}, {0, 0, 0}})
    File.write!(Path.join(root, ".aiur-test-tickets.json"), ~s({"tickets":[99,100,101]}))
    engine = Path.join(libexec, "aiur-engine.sh")

    File.write!(
      engine,
      "#!/usr/bin/env bash\n" <>
        "if [ \"${1:-}\" = __identity ]; then echo AIUR_INSTANCE_KEY=0123456789; exit; fi\n" <>
        "if [ -n \"${AIUR_ENGINE_TRACE:-}\" ]; then\n" <>
        "  {\n" <>
        "    echo '---'\n" <>
        "    echo \"ENGINE_ARGS: $*\"\n" <>
        "    echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "    echo \"AIUR_DEV_TEST_TICKET_IDS: ${AIUR_DEV_TEST_TICKET_IDS:-}\"\n" <>
        "    echo \"AIUR_GITHUB_BUDGET_DIR: ${AIUR_GITHUB_BUDGET_DIR:-}\"\n" <>
        "    echo \"AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "    echo \"AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "    echo \"XDG_CONFIG_HOME: ${XDG_CONFIG_HOME:-}\"\n" <>
        "    echo \"XDG_STATE_HOME: ${XDG_STATE_HOME:-}\"\n" <>
        "    echo \"XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "    echo \"AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n" <>
        "    echo \"OPENCODE_PATH: $(command -v opencode 2>/dev/null || true)\"\n" <>
        "  } >> \"$AIUR_ENGINE_TRACE\"\n" <>
        "fi\n" <>
        ~S|if [ -n "${AIUR_FAKE_ENGINE_TRANSIENT_ONCE:-}" ] && [ ! -e "$AIUR_FAKE_ENGINE_TRANSIENT_ONCE" ]; then| <>
        "\n" <>
        "  : > \"$AIUR_FAKE_ENGINE_TRANSIENT_ONCE\"\n" <>
        "  : > \"$AIUR_CONTROL_RELEASE_RETRY_SIGNAL\"\n" <>
        "  exit 75\n" <>
        "fi\n" <>
        ~S|[ -n "${AIUR_FAKE_ENGINE_EXIT:-}" ] && exit "$AIUR_FAKE_ENGINE_EXIT"| <>
        "\n" <>
        ~S|if [ -n "${AIUR_FAKE_ENGINE_CHECK_NO_LOCK:-}" ] && [ -e "$AIUR_FAKE_ENGINE_CHECK_NO_LOCK" ]; then| <>
        "\n" <>
        "  echo \"FAIL: build lock still present at engine exec\"\n" <>
        "  exit 1\n" <>
        "fi\n" <>
        "echo \"ENGINE_ARGS: $*\"\n" <>
        "echo \"RELEASE_DIR: ${AIUR_RELEASE_DIR:-}\"\n" <>
        "echo \"RESTART_BUILD_CMD: ${AIUR_RESTART_BUILD_CMD:-}\"\n" <>
        "echo \"AIUR_DEBUG: ${AIUR_DEBUG:-}\"\n" <>
        "echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "echo \"AIUR_DEV_TEST_TICKET_IDS: ${AIUR_DEV_TEST_TICKET_IDS:-}\"\n" <>
        "echo \"AIUR_GITHUB_BUDGET_DIR: ${AIUR_GITHUB_BUDGET_DIR:-}\"\n" <>
        "echo \"AIUR_RECORD_TEST_TICKET_IDS: ${AIUR_RECORD_TEST_TICKET_IDS:-}\"\n" <>
        "echo \"AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "echo \"AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "echo \"XDG_CONFIG_HOME: ${XDG_CONFIG_HOME:-}\"\n" <>
        "echo \"XDG_STATE_HOME: ${XDG_STATE_HOME:-}\"\n" <>
        "echo \"XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "echo \"AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n" <>
        "echo \"OPENCODE_PATH: $(command -v opencode 2>/dev/null || true)\"\n"
    )

    File.chmod!(engine, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    root
  end

  def engine_trace(root), do: Path.join(root, "engine.trace")

  def fake_agent_repo(issue) do
    root =
      Path.join([
        isolated_tmp_root(),
        "aiur-workspaces",
        "repo",
        to_string(issue),
        "aiurdev-shim-#{System.unique_integer([:positive])}"
      ])

    fake_repo(root)
  end

  def seed_ready_release(root) do
    src = Path.join(root, "src")
    release_vsn_dir = Path.join([src, "_build", "dev", "rel", "aiur", "releases", "0.0.3"])
    erts_bin_dir = Path.join([src, "_build", "dev", "rel", "aiur", "erts-16.4", "bin"])

    File.mkdir_p!(Path.join(src, "bin"))
    File.mkdir_p!(Path.join([src, "_build", "dev", "rel", "aiur", "bin"]))
    File.mkdir_p!(release_vsn_dir)
    File.mkdir_p!(erts_bin_dir)

    for path <- [
          Path.join([src, "bin", "aiur"]),
          Path.join([src, "_build", "dev", "rel", "aiur", "bin", "aiur"]),
          Path.join([release_vsn_dir, "elixir"]),
          Path.join([erts_bin_dir, "epmd"])
        ] do
      File.write!(path, "#!/usr/bin/env bash\n")
      File.chmod!(path, 0o755)
    end

    File.write!(Path.join([src, "_build", "dev", "rel", "aiur", "releases", "start_erl.data"]), "16.4 0.0.3")
    File.write!(Path.join(release_vsn_dir, "start_clean.boot"), "")
    File.write!(Path.join(release_vsn_dir, "vm.args"), "")
    File.write!(Path.join(release_vsn_dir, "sys.config"), "")
    lock_sha = src |> Path.join("mix.lock") |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    File.write!(Path.join([src, "_build", "dev", "aiurdev-deps-lock-sha"]), lock_sha <> "\n")

    # A real build stamps the release with the commit it came from. These fake
    # roots live outside any git repo, so "unknown" is exactly what the shim
    # would write here — and an unknown SHA means the mtime sweep, not the SHA
    # comparison, decides staleness. `stamp_release/2` overrides it where a test
    # is about the SHA.
    stamp_release(root)
  end

  def stamp_release(root, sha \\ "unknown") do
    lock_sha = root |> Path.join("src/mix.lock") |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    File.write!(
      release_stamp_path(root),
      "repo_root=#{root}\nsource_sha=#{sha}\ndeps_lock_sha=#{lock_sha}\ndirty=unknown\nbuilt_at=1970-01-01T00:00:00Z\n"
    )
  end

  def release_stamp_path(root),
    do: Path.join([root, "src", "_build", "dev", "rel", "aiur", "AIUR_BUILD_STAMP"])

  # The SHA half of staleness only exists inside a work tree, so the tests that
  # exercise it need a real (if empty) one. Identity is pinned per-invocation so
  # the run never depends on the host's git config.
  def init_git_repo(root) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end

    git.(["init", "--quiet"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "test"])
    git.(["commit", "--quiet", "--allow-empty", "-m", "seed"])
  end

  def git_head(root) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    String.trim(sha)
  end

  # A fake mise that records how it was invoked and succeeds, so `--test`'s
  # `mise exec -- mix aiur.test.reset` runs without a real toolchain.
  def fake_mise do
    path = Aiur.TestSupport.tmp_root!("aiurdev-mise")
    opencode_dir = path <> ".opencode"

    File.write!(
      path,
      ~S"""
      #!/usr/bin/env bash
      if [ "${1:-}" = "where" ]; then
        mkdir -p "${0}.opencode"
        printf '%s\\n' '#!/usr/bin/env bash' > "${0}.opencode/opencode"
        chmod +x "${0}.opencode/opencode"
        echo "${0}.opencode"
        exit 0
      fi

      echo "MISE: $*"
      echo "MISE_AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}"
      echo "MISE_AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}"
      echo "MISE_AIUR_DEV_TEST_TICKET_IDS: ${AIUR_DEV_TEST_TICKET_IDS:-}"
      echo "MISE_AIUR_GITHUB_BUDGET_DIR: ${AIUR_GITHUB_BUDGET_DIR:-}"
      echo "MISE_AIUR_DEV_TEST_RUN_ID: ${AIUR_DEV_TEST_RUN_ID:-}"
      echo "MISE_AIUR_DEV_TEST_STATE_DIR: ${AIUR_DEV_TEST_STATE_DIR:-}"
      echo "MISE_AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}"
      echo "MISE_XDG_CONFIG_HOME: ${XDG_CONFIG_HOME:-}"
      echo "MISE_XDG_STATE_HOME: ${XDG_STATE_HOME:-}"
      echo "MISE_XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}"
      echo "MISE_AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}"
      if [ "${1:-}" = "exec" ] && [ "${3:-}" = "npm" ]; then
        [ -z "${AIUR_FAKE_NPM_LOG:-}" ] || echo "${*:3}" >> "$AIUR_FAKE_NPM_LOG"
        [ "${AIUR_FAKE_NPM_FAIL:-}" != "${4:-}" ] || exit 8
        if [ "${4:-}" = "run" ]; then
          mkdir -p ../priv/static/vendor/elk/0.11.1
          for file in elk-worker.min.js aiur-layout-worker.js aiur-layout-client.js; do
            echo generated > "../priv/static/vendor/elk/0.11.1/$file"
          done
        fi
        exit 0
      fi
      if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--" ] && [ "${3:-}" = "mix" ]; then
        case "${4:-}" in
          deps.get|compile)
            mkdir -p deps _build
            if [ -n "${AIUR_FAKE_MISE_ORDER_LOG:-}" ]; then
              echo "${4:-}" >> "$AIUR_FAKE_MISE_ORDER_LOG"
            fi
            if [ "${4:-}" = "deps.get" ] && [ -n "${AIUR_FAKE_MISE_DEPS_LOG:-}" ]; then
              echo "deps.get $*" >> "$AIUR_FAKE_MISE_DEPS_LOG"
            fi
            if [ "${4:-}" = "compile" ] && [ -n "${AIUR_FAKE_MISE_COMPILE_LOG:-}" ]; then
              echo "compile $*" >> "$AIUR_FAKE_MISE_COMPILE_LOG"
            fi
            if [ "${4:-}" = "compile" ]; then
              mkdir -p _build/dev/lib/aiur/ebin
              printf 'generation-2' > _build/dev/lib/aiur/ebin/schema.beam
              printf 'generation-2' > _build/dev/lib/aiur/ebin/consumer.beam
            fi
            ;;
          release)
            release_path="${7:-_build/dev/rel/aiur}"
            launcher_path="${AIUR_MIX_CLI_LAUNCHER_PATH:-bin/aiur}"
            if [ -n "${AIUR_FAKE_MISE_RELEASE_LOG:-}" ]; then
              echo "release start $$" >> "$AIUR_FAKE_MISE_RELEASE_LOG"
            fi
            if [ -n "${AIUR_FAKE_MISE_RELEASE_SLEEP:-}" ]; then
              sleep "$AIUR_FAKE_MISE_RELEASE_SLEEP"
            fi
            mkdir -p "$(dirname "$launcher_path")" "$release_path/bin" "$release_path/lib/aiur-0.0.3/ebin" "$release_path/releases/0.0.3" "$release_path/erts-16.4/bin"
            printf '#!/usr/bin/env bash\nrelease_root="%s"\n' "${AIUR_MIX_RELEASE_FINAL_DIR:-_build/dev/rel/aiur}" > "$launcher_path"
            echo '#!/usr/bin/env bash' > "$release_path/bin/aiur"
            echo '#!/usr/bin/env bash' > "$release_path/erts-16.4/bin/epmd"
            chmod +x "$launcher_path" "$release_path/bin/aiur" "$release_path/erts-16.4/bin/epmd"
            echo '16.4 0.0.3' > "$release_path/releases/start_erl.data"
            : > "$release_path/releases/0.0.3/start_clean.boot"
            : > "$release_path/releases/0.0.3/vm.args"
            : > "$release_path/releases/0.0.3/sys.config"
            if [ -f _build/dev/lib/aiur/ebin/schema.beam ] && [ -f _build/dev/lib/aiur/ebin/consumer.beam ]; then
              cp _build/dev/lib/aiur/ebin/schema.beam "$release_path/lib/aiur-0.0.3/ebin/schema.beam"
              cp _build/dev/lib/aiur/ebin/consumer.beam "$release_path/lib/aiur-0.0.3/ebin/consumer.beam"
            fi
            if [ "${AIUR_FAKE_MISE_FAIL_RELEASE:-}" = "1" ]; then
              exit 9
            fi
            echo '#!/usr/bin/env bash' > "$release_path/releases/0.0.3/elixir"
            chmod +x "$release_path/releases/0.0.3/elixir"
            ;;
        esac
      fi
      exit 0
      """
    )

    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm(path)
      Aiur.TestCleanup.rm_rf!(opencode_dir)
    end)

    path
  end

  # Throwaway HOME keeps log-clearing tests away from real run evidence.
  def sandbox_home do
    home = Path.join(isolated_tmp_root(), "aiurdev-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, ".aiur", "logs", "old-session"]))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(home) end)
    home
  end

  def run_shim(args, env, opts \\ []) do
    base_env = [
      {"AIUR_AGENT_WORKSPACE", nil},
      {"AIUR_AGENT_IR_SANDBOX", nil},
      {"AIUR_AGENT_IR_ROOT", nil},
      {"AIUR_DEV_TEST_TICKET_IDS", nil},
      {"AIUR_OPENCODE_BRIDGE_PORT", nil}
    ]

    cwd = Keyword.get(opts, :cd, isolated_cwd())
    File.mkdir_p!(cwd)

    script = Keyword.get(opts, :script, @script)

    System.cmd("bash", ["-c", "cd -P -- \"$1\" && shift && exec bash \"$@\"", "aiurdev-test", cwd, script | args],
      env: base_env ++ env ++ [{"PWD", cwd}],
      stderr_to_stdout: true
    )
  end

  # Agent workspaces commonly live under /.../aiur-workspaces/..., which the
  # dev shim intentionally recognizes as an agent workspace even when its
  # marker is cleared. Keep tests for ordinary temporary directories outside
  # that host path; tests for workspace detection pass their own explicit cwd.
  defp isolated_cwd do
    isolated_tmp_root()
  end

  # A fake root that also looks like a CHECKOUT from the outside — the three
  # markers the shim walks up the cwd for. `fake_repo/1` alone deliberately does
  # not, so the targeting guard stays invisible to every test that is not about
  # it. The shim is copied rather than symlinked: the shim resolves its own
  # symlinks, so a link would resolve straight back to the real repo and the
  # fake checkout would never be the target.
  def fake_checkout(root \\ nil) do
    root = if root, do: fake_repo(root), else: fake_repo()
    shim = Path.join([root, "scripts", "aiurdev"])

    File.mkdir_p!(Path.dirname(shim))
    File.cp!(@script, shim)
    copy_shim_libs!(Path.dirname(shim))
    File.chmod!(shim, 0o755)
    File.write!(Path.join([root, "src", "mix.exs"]), "")

    {root, shim}
  end

  # ~/.local/bin/aiurdev -> <checkout>/scripts/aiurdev, the install that makes
  # the divergence reachable in the first place.
  def global_shim(target) do
    bin = Aiur.TestSupport.tmp_root!("aiurdev-bin")
    link = Path.join(bin, "aiurdev")

    File.mkdir_p!(bin)
    File.ln_s!(target, link)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(bin) end)

    link
  end

  # The physical path, which is what the shim compares against — `System.tmp_dir!`
  # is a symlink on some hosts (macOS `/tmp` -> `/private/tmp`).
  def physical(path), do: File.cd!(path, &File.cwd!/0)

  # test can signal the shim itself while it holds the rebuild lock.
  def spawn_shim_with_pid(root, args) do
    pid_file = Path.join(root, "shim.pid")
    wrapper = Path.join(root, "shim-wrapper.sh")

    File.write!(wrapper, """
    #!/usr/bin/env bash
    echo $$ > #{pid_file}
    exec bash #{@script} #{Enum.join(args, " ")}
    """)

    File.chmod!(wrapper, 0o755)
    {pid_file, wrapper}
  end

  def wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline, fun.())
  end

  def wait_until(_fun, _deadline, true), do: :ok

  def wait_until(fun, deadline, false) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "timed out waiting for condition"
    else
      Process.sleep(20)
      wait_until(fun, deadline, fun.())
    end
  end
end
