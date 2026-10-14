defmodule Aiur.TestSupport.AiurdevCase do
  @moduledoc false
  # Shared fixtures for the scripts/aiurdev shim tests (ScriptsAiurdev*Test).

  import ExUnit.Callbacks, only: [on_exit: 1]

  @script Path.expand("../../../scripts/aiurdev", __DIR__)
  def script, do: @script

  # The shim sources scripts/lib/aiurdev-*.sh next to itself, so copies need them.
  def copy_shim_libs!(dir), do: File.cp_r!(Path.join(Path.dirname(@script), "lib"), Path.join(dir, "lib"))

  # A fake repo root whose engine just echoes how the shim invoked it, so we can
  # assert on AIUR_RELEASE_DIR + forwarded args without building a real release.
  def fake_repo(root \\ Aiur.TestSupport.tmp_root!("aiurdev-shim")) do
    libexec = Path.join([root, "packaging", "npm", "aiur-cli", "libexec"])
    File.mkdir_p!(libexec)
    # `--test` resets the sandbox from $repo_root/src; the dir must exist to cd into.
    File.mkdir_p!(Path.join(root, "src"))
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
        System.tmp_dir!(),
        "aiur-workspaces",
        "repo",
        to_string(issue),
        Aiur.TestSupport.tmp_root!("aiurdev-shim")
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

    # A real build stamps the release with the commit it came from. These fake
    # roots live outside any git repo, so "unknown" is exactly what the shim
    # would write here — and an unknown SHA means the mtime sweep, not the SHA
    # comparison, decides staleness. `stamp_release/2` overrides it where a test
    # is about the SHA.
    stamp_release(root)
  end

  def stamp_release(root, sha \\ "unknown") do
    File.write!(
      release_stamp_path(root),
      "repo_root=#{root}\nsource_sha=#{sha}\ndirty=unknown\nbuilt_at=1970-01-01T00:00:00Z\n"
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
      echo "MISE_AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}"
      echo "MISE_XDG_CONFIG_HOME: ${XDG_CONFIG_HOME:-}"
      echo "MISE_XDG_STATE_HOME: ${XDG_STATE_HOME:-}"
      echo "MISE_XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}"
      echo "MISE_AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}"
      if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--" ] && [ "${3:-}" = "mix" ]; then
        case "${4:-}" in
          deps.get|compile)
            mkdir -p deps _build
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
            if [ -n "${AIUR_FAKE_MISE_RELEASE_LOG:-}" ]; then
              echo "release start $$" >> "$AIUR_FAKE_MISE_RELEASE_LOG"
            fi
            if [ -n "${AIUR_FAKE_MISE_RELEASE_SLEEP:-}" ]; then
              sleep "$AIUR_FAKE_MISE_RELEASE_SLEEP"
            fi
            mkdir -p bin _build/dev/rel/aiur/bin _build/dev/rel/aiur/lib/aiur-0.0.3/ebin _build/dev/rel/aiur/releases/0.0.3 _build/dev/rel/aiur/erts-16.4/bin
            echo '#!/usr/bin/env bash' > bin/aiur
            echo '#!/usr/bin/env bash' > _build/dev/rel/aiur/bin/aiur
            echo '#!/usr/bin/env bash' > _build/dev/rel/aiur/erts-16.4/bin/epmd
            chmod +x bin/aiur _build/dev/rel/aiur/bin/aiur _build/dev/rel/aiur/erts-16.4/bin/epmd
            echo '16.4 0.0.3' > _build/dev/rel/aiur/releases/start_erl.data
            : > _build/dev/rel/aiur/releases/0.0.3/start_clean.boot
            : > _build/dev/rel/aiur/releases/0.0.3/vm.args
            : > _build/dev/rel/aiur/releases/0.0.3/sys.config
            if [ -f _build/dev/lib/aiur/ebin/schema.beam ] && [ -f _build/dev/lib/aiur/ebin/consumer.beam ]; then
              cp _build/dev/lib/aiur/ebin/schema.beam _build/dev/rel/aiur/lib/aiur-0.0.3/ebin/schema.beam
              cp _build/dev/lib/aiur/ebin/consumer.beam _build/dev/rel/aiur/lib/aiur-0.0.3/ebin/consumer.beam
            fi
            if [ "${AIUR_FAKE_MISE_FAIL_RELEASE:-}" = "1" ]; then
              exit 9
            fi
            echo '#!/usr/bin/env bash' > _build/dev/rel/aiur/releases/0.0.3/elixir
            chmod +x _build/dev/rel/aiur/releases/0.0.3/elixir
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
    home = Aiur.TestSupport.tmp_root!("aiurdev-home")
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

    System.cmd("bash", [Keyword.get(opts, :script, @script) | args],
      env: base_env ++ env,
      cd: Keyword.get(opts, :cd, System.tmp_dir!()),
      stderr_to_stdout: true
    )
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
