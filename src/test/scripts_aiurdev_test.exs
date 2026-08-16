defmodule ScriptsAiurdevTest do
  # async: false — the agent-workspace fallback tests `File.cd!` the BEAM into a
  # temp dir to resolve the real (symlink-expanded) PWD the shim will see. The
  # working directory is process-global, so running this concurrently with the
  # rest of the suite races ExUnit's parallel test compiler (which resolves test
  # files via relative paths) and surfaces as a `MatchError {:error, :enoent}`
  # compiling some unrelated `test/...` file under the temp cwd (#589).
  use ExUnit.Case, async: false

  # aiurdev is now a thin dev shim: it resolves the repo-local release, rebuilds
  # it when stale, and execs the shared engine with AIUR_RELEASE_DIR set. The
  # command surface itself is covered by AiurEngineTest; here we only verify the
  # shim's contract (release dir, arg forwarding, the in-tmux guard, build skip).
  @script Path.expand("../../scripts/aiurdev", __DIR__)

  # A fake repo root whose engine just echoes how the shim invoked it, so we can
  # assert on AIUR_RELEASE_DIR + forwarded args without building a real release.
  defp fake_repo(
         root \\ Path.join(
           System.tmp_dir!(),
           "aiurdev-shim-#{System.unique_integer([:positive])}"
         )
       ) do
    libexec = Path.join([root, "packaging", "npm", "aiur-cli", "libexec"])
    File.mkdir_p!(libexec)
    # `--test` resets the sandbox from $repo_root/src; the dir must exist to cd into.
    File.mkdir_p!(Path.join(root, "src"))
    engine = Path.join(libexec, "aiur-engine.sh")

    File.write!(
      engine,
      "#!/usr/bin/env bash\n" <>
        "if [ -n \"${AIUR_ENGINE_TRACE:-}\" ]; then\n" <>
        "  {\n" <>
        "    echo '---'\n" <>
        "    echo \"ENGINE_ARGS: $*\"\n" <>
        "    echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
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
        "echo \"ENGINE_ARGS: $*\"\n" <>
        "echo \"RELEASE_DIR: ${AIUR_RELEASE_DIR:-}\"\n" <>
        "echo \"RESTART_BUILD_CMD: ${AIUR_RESTART_BUILD_CMD:-}\"\n" <>
        "echo \"AIUR_DEBUG: ${AIUR_DEBUG:-}\"\n" <>
        "echo \"AIUR_AGENT_IR_SANDBOX: ${AIUR_AGENT_IR_SANDBOX:-}\"\n" <>
        "echo \"AIUR_BG_STATE_DIR: ${AIUR_BG_STATE_DIR:-}\"\n" <>
        "echo \"AIUR_LOGS_ROOT: ${AIUR_LOGS_ROOT:-}\"\n" <>
        "echo \"XDG_CONFIG_HOME: ${XDG_CONFIG_HOME:-}\"\n" <>
        "echo \"XDG_STATE_HOME: ${XDG_STATE_HOME:-}\"\n" <>
        "echo \"XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}\"\n" <>
        "echo \"AIUR_OPENCODE_BRIDGE_PORT: ${AIUR_OPENCODE_BRIDGE_PORT:-}\"\n" <>
        "echo \"OPENCODE_PATH: $(command -v opencode 2>/dev/null || true)\"\n"
    )

    File.chmod!(engine, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp engine_trace(root), do: Path.join(root, "engine.trace")

  defp fake_agent_repo(issue) do
    root =
      Path.join([
        System.tmp_dir!(),
        "aiur-workspaces",
        "repo",
        to_string(issue),
        "aiurdev-shim-#{System.unique_integer([:positive])}"
      ])

    fake_repo(root)
  end

  defp seed_ready_release(root) do
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

  defp stamp_release(root, sha \\ "unknown") do
    File.write!(
      release_stamp_path(root),
      "repo_root=#{root}\nsource_sha=#{sha}\ndirty=unknown\nbuilt_at=1970-01-01T00:00:00Z\n"
    )
  end

  defp release_stamp_path(root),
    do: Path.join([root, "src", "_build", "dev", "rel", "aiur", "AIUR_BUILD_STAMP"])

  # The SHA half of staleness only exists inside a work tree, so the tests that
  # exercise it need a real (if empty) one. Identity is pinned per-invocation so
  # the run never depends on the host's git config.
  defp init_git_repo(root) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end

    git.(["init", "--quiet"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "test"])
    git.(["commit", "--quiet", "--allow-empty", "-m", "seed"])
  end

  defp git_head(root) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    String.trim(sha)
  end

  # A fake mise that records how it was invoked and succeeds, so `--test`'s
  # `mise exec -- mix aiur.test.reset` runs without a real toolchain.
  defp fake_mise do
    path = Path.join(System.tmp_dir!(), "aiurdev-mise-#{System.unique_integer([:positive])}")
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
      File.rm_rf(opencode_dir)
    end)

    path
  end

  # A throwaway HOME so `--clear` (which wipes ~/.aiur/logs) never touches the
  # real one. Seeds a stale session dir the caller can assert was removed.
  defp sandbox_home do
    home = Path.join(System.tmp_dir!(), "aiurdev-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, ".aiur", "logs", "old-session"]))
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end

  defp run_shim(args, env, opts \\ []) do
    base_env = [
      {"AIUR_AGENT_WORKSPACE", nil},
      {"AIUR_AGENT_IR_SANDBOX", nil},
      {"AIUR_AGENT_IR_ROOT", nil},
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
  defp fake_checkout(root \\ nil) do
    root = if root, do: fake_repo(root), else: fake_repo()
    shim = Path.join([root, "scripts", "aiurdev"])

    File.mkdir_p!(Path.dirname(shim))
    File.cp!(@script, shim)
    File.chmod!(shim, 0o755)
    File.write!(Path.join([root, "src", "mix.exs"]), "")

    {root, shim}
  end

  # ~/.local/bin/aiurdev -> <checkout>/scripts/aiurdev, the install that makes
  # the divergence reachable in the first place.
  defp global_shim(target) do
    bin = Path.join(System.tmp_dir!(), "aiurdev-bin-#{System.unique_integer([:positive])}")
    link = Path.join(bin, "aiurdev")

    File.mkdir_p!(bin)
    File.ln_s!(target, link)
    on_exit(fn -> File.rm_rf!(bin) end)

    link
  end

  # The physical path, which is what the shim compares against — `System.tmp_dir!`
  # is a symlink on some hosts (macOS `/tmp` -> `/private/tmp`).
  defp physical(path), do: File.cd!(path, &File.cwd!/0)

  test "execs the engine with the repo-local release dir and forwards args" do
    root = fake_repo()

    {out, code} =
      run_shim(["status", "--all"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert code == 0
    assert out =~ "ENGINE_ARGS: status --all"
    assert out =~ "RELEASE_DIR: #{root}/src/_build/dev/rel/aiur"
  end

  test "refuses to run inside an existing tmux session" do
    root = fake_repo()

    {out, code} =
      run_shim([], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", "/tmp/fake,1,0"}])

    assert code == 1
    assert out =~ "already inside a tmux session"
  end

  test "AIUR_SKIP_BUILD short-circuits the rebuild" do
    root = fake_repo()

    {out, 0} =
      run_shim(["--help"], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

    refute out =~ "rebuilding"
    refute out =~ "force-rebuild"
  end

  test "AIUR_SKIP_BUILD still pins opencode for launch paths" do
    root = fake_repo()
    mise = fake_mise()

    # `restart` starts a session too, so it belongs to the same class as `--bg`.
    for args <- [["--bg"], ["restart"]] do
      {out, 0} =
        run_shim(args, [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_SKIP_BUILD", "1"},
          {"AIUR_MISE_BIN", mise},
          {"TMUX", nil}
        ])

      assert out =~ "ENGINE_ARGS: #{Enum.join(args, " ")}"
      assert out =~ "OPENCODE_PATH: #{mise}.opencode/opencode"
    end
  end

  test "control commands do not require a pinned opencode install" do
    root = fake_repo()

    {out, 0} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", Path.join(root, "missing-mise")},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: status"
  end

  test "launch paths fail closed when pinned opencode is unavailable" do
    root = fake_repo()

    for args <- [["--bg"], ["restart"]] do
      {out, 64} =
        run_shim(args, [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_SKIP_BUILD", "1"},
          {"AIUR_MISE_BIN", Path.join(root, "missing-mise")},
          {"TMUX", nil}
        ])

      assert out =~ "mise not found"
      # For restart this also proves the tool check precedes the stop: the
      # engine — and therefore cmd_stop — is never reached.
      refute out =~ "ENGINE_ARGS:"
    end
  end

  test "concurrent stale rebuilds serialize and reuse the completed release" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    env = [
      {"AIUR_REPO_ROOT", root},
      {"AIUR_MISE_BIN", mise},
      {"AIUR_FAKE_MISE_RELEASE_LOG", log},
      {"AIUR_FAKE_MISE_RELEASE_SLEEP", "0.5"},
      {"TMUX", nil}
    ]

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> run_shim(["status"], env) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.all?(results, fn {_out, code} -> code == 0 end)

    release_starts =
      log
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(release_starts) == 1
    assert File.exists?(Path.join([root, "src", "_build", "dev", "rel", "aiur", "releases", "0.0.3", "elixir"]))
  end

  test "stale-source control commands reuse a ready release without rebuilding" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    for {args, expected} <- [
          {["agents"], "ENGINE_ARGS: agents"},
          {["status"], "ENGINE_ARGS: status"},
          {["set", "max-agents", "3"], "ENGINE_ARGS: set max-agents 3"},
          {["pause", "--all"], "ENGINE_ARGS: pause --all"},
          {["resume", "539"], "ENGINE_ARGS: resume 539"},
          {["stop"], "ENGINE_ARGS: stop"},
          {["cleanup-stale"], "ENGINE_ARGS: cleanup-stale"},
          {["message", "539", "hello"], "ENGINE_ARGS: message 539 hello"}
        ] do
      {out, 0} =
        run_shim(args, [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      assert out =~ expected
      refute out =~ "rebuilding"
    end

    refute File.exists?(log), "stale control commands should not invoke mix release"
  end

  test "ready control commands bypass a held rebuild lock" do
    root = fake_repo()
    mise = fake_mise()
    lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])

    seed_ready_release(root)
    File.mkdir_p!(lock)
    on_exit(fn -> File.rm_rf(lock) end)

    {out, 0} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: status"
    refute out =~ "waiting for aiurdev rebuild lock"
  end

  test "control commands retry once when the ready release changes before rpc" do
    root = fake_repo()
    mise = fake_mise()
    trace = engine_trace(root)
    transient = Path.join(root, "transient-once")

    seed_ready_release(root)

    {out, 0} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_FAKE_ENGINE_TRANSIENT_ONCE", transient},
        {"TMUX", nil}
      ])

    assert out =~ "dev release changed during control command"
    assert out =~ "ENGINE_ARGS: status"
    assert File.read!(trace) |> String.split("ENGINE_ARGS: status") |> Enum.count() == 3
  end

  test "an ordinary control exit 75 is not retried without the release signal" do
    root = fake_repo()
    mise = fake_mise()
    trace = engine_trace(root)

    seed_ready_release(root)

    {_, 75} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_FAKE_ENGINE_EXIT", "75"},
        {"TMUX", nil}
      ])

    assert File.read!(trace) |> String.split("ENGINE_ARGS: status") |> Enum.count() == 2
  end

  test "control commands rebuild when any ready-release artifact is missing" do
    for {missing, remove_artifact} <- [
          {"start_clean.boot",
           fn src ->
             File.rm!(Path.join([src, "_build", "dev", "rel", "aiur", "releases", "0.0.3", "start_clean.boot"]))
           end},
          {"vm.args",
           fn src ->
             File.rm!(Path.join([src, "_build", "dev", "rel", "aiur", "releases", "0.0.3", "vm.args"]))
           end},
          {"sys.config",
           fn src ->
             File.rm!(Path.join([src, "_build", "dev", "rel", "aiur", "releases", "0.0.3", "sys.config"]))
           end},
          {"epmd",
           fn src ->
             File.rm!(Path.join([src, "_build", "dev", "rel", "aiur", "erts-16.4", "bin", "epmd"]))
           end}
        ] do
      root = fake_repo()
      mise = fake_mise()
      log = Path.join(root, "release.log")
      src = Path.join(root, "src")

      seed_ready_release(root)
      remove_artifact.(src)

      {out, 0} =
        run_shim(["agents"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      assert out =~ "rebuilding", "#{missing} should make release_ready fail"
      assert out =~ "ENGINE_ARGS: agents"
      assert File.exists?(log), "#{missing} should rebuild before control RPC"
    end
  end

  test "stale-source run paths still rebuild a ready release" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert out =~ "rebuilding"
    assert out =~ "ENGINE_ARGS: --bg"
    assert File.exists?(log), "run paths should still invoke mix release when sources are stale"
  end

  test "stale rebuild compiles schema and consumer as one generation" do
    root = fake_repo()
    mise = fake_mise()
    src = Path.join(root, "src")
    compile_log = Path.join(root, "compile.log")
    release_app = Path.join([src, "_build", "dev", "rel", "aiur", "lib", "aiur-0.0.3", "ebin"])

    seed_ready_release(root)
    File.mkdir_p!(Path.join([src, "_build", "dev", "lib", "aiur", "ebin"]))
    File.mkdir_p!(release_app)
    File.write!(Path.join([src, "_build", "dev", "lib", "aiur", "ebin", "schema.beam"]), "generation-1")
    File.write!(Path.join([src, "_build", "dev", "lib", "aiur", "ebin", "consumer.beam"]), "generation-1")
    File.write!(Path.join(release_app, "schema.beam"), "generation-1")
    File.write!(Path.join(release_app, "consumer.beam"), "generation-1")
    File.write!(Path.join(src, "generation"), "generation-2")
    File.mkdir_p!(Path.join(src, "lib"))
    File.write!(Path.join([src, "lib", "generation.ex"]), "# generation-2")
    File.touch!(Path.join([src, "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(Path.join([src, "lib", "generation.ex"]), {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_COMPILE_LOG", compile_log},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: --bg"
    assert File.read!(compile_log) =~ "compile exec -- mix compile --force"
    assert File.read!(Path.join([src, "_build", "dev", "lib", "aiur", "ebin", "schema.beam"])) == "generation-2"
    assert File.read!(Path.join([src, "_build", "dev", "lib", "aiur", "ebin", "consumer.beam"])) == "generation-2"
    assert File.read!(Path.join(release_app, "schema.beam")) == "generation-2"
    assert File.read!(Path.join(release_app, "consumer.beam")) == "generation-2"
  end

  test "failed rebuild removes the incomplete release and exits nonzero" do
    root = fake_repo()
    mise = fake_mise()

    {out, code} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
        {"TMUX", nil}
      ])

    assert code == 9
    assert out =~ "aiur release rebuild failed"
    refute File.exists?(Path.join([root, "src", "_build", "dev", "rel", "aiur"]))
  end

  test "restart hands the engine a rebuild command instead of rebuilding first" do
    # The engine runs this command between its stop and its start. Rebuilding
    # here instead would rewrite the release under the still-live BEAM — the
    # exact ordering `restart` exists to avoid — so a stale tree must reach the
    # engine unbuilt, with only a complete-enough release to issue the stop.
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["restart"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: restart"

    # The repo root is pinned into the command, not left to the child to
    # re-derive from its own path in a process the engine launches from the
    # operator's cwd — by the stop, the target is already settled.
    assert out =~ ~r/RESTART_BUILD_CMD: AIUR_REPO_ROOT=\S*\s+\S*aiurdev __ensure-build/
    assert out =~ "AIUR_REPO_ROOT=#{root}"
    refute out =~ "rebuilding"
    refute File.exists?(log), "restart must not rebuild before the engine stops the daemon"

    # The flag has to survive the shim's own passthrough parsing to reach the
    # engine, and it must not change which pre-dispatch path restart takes.
    {no_build_out, 0} =
      run_shim(["restart", "--no-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert no_build_out =~ "ENGINE_ARGS: restart --no-build"
    refute File.exists?(log)
  end

  test "the rebuild command the shim emits actually runs, from a path with a space" do
    # Both suites otherwise stub the opposite side of this seam. Run the exact
    # string the engine would run, so a broken path hop, a lost `__ensure-build`
    # argument, or unquoted whitespace fails here instead of in production —
    # after the daemon has already been stopped.
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    shim_dir = Path.join(System.tmp_dir!(), "aiur dev shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(shim_dir)
    shim = Path.join(shim_dir, "aiurdev")
    File.cp!(@script, shim)
    File.chmod!(shim, 0o755)
    on_exit(fn -> File.rm_rf!(shim_dir) end)

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    env = [
      {"AIUR_REPO_ROOT", root},
      {"AIUR_MISE_BIN", mise},
      {"AIUR_FAKE_MISE_RELEASE_LOG", log},
      {"TMUX", nil}
    ]

    {out, 0} = System.cmd("bash", [shim, "restart"], env: env, stderr_to_stdout: true)

    [_, build_cmd] = Regex.run(~r/RESTART_BUILD_CMD: (.+)/, out)
    assert build_cmd =~ "__ensure-build"

    # Exactly how the engine invokes it, receipt and all.
    receipt = Path.join(root, "receipt")

    {build_out, 0} =
      System.cmd("bash", ["-c", build_cmd],
        env: [{"AIUR_RESTART_BUILD_RECEIPT", receipt} | env],
        stderr_to_stdout: true
      )

    assert build_out =~ "the daemon is stopped until this finishes"
    assert build_out =~ "rebuilding"
    assert File.exists?(log)
    assert File.read!(receipt) =~ "release_dir=#{root}/src/_build/dev/rel/aiur"
  end

  test "the rebuild command is exported only for restart" do
    # Otherwise the daemon and every agent it spawns inherits a rebuild bound to
    # this checkout, and an inner `aiur restart` would silently act on it.
    root = fake_repo()

    for args <- [["status"], ["--help"]] do
      {out, 0} =
        run_shim(args, [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

      assert out =~ ~r/^RESTART_BUILD_CMD: *$/m
    end
  end

  test "the deferred rebuild runs even when TMUX is set" do
    # The engine's `bash -c` inherits the caller's environment. If the shim's
    # tmux guard caught this entry point, an inherited $TMUX would report a
    # rebuild failure for a rebuild that never ran — with the daemon stopped.
    root = fake_repo()
    mise = fake_mise()

    seed_ready_release(root)

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", "/tmp/fake,1,0"}
      ])

    refute out =~ "already inside a tmux session"
  end

  test "the deferred rebuild entry point rebuilds a stale release without launching" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)
    File.mkdir_p!(Path.join([root, "src", "lib"]))
    newer = Path.join([root, "src", "lib", "newer.ex"])
    File.write!(newer, "# stale after release\n")
    File.touch!(Path.join([root, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    assert out =~ "rebuilding"
    assert File.exists?(log)
    refute out =~ "ENGINE_ARGS:", "the rebuild step must not start a session itself"
  end

  test "the deferred rebuild is a no-op for a release the sources have not outrun" do
    root = fake_repo()
    mise = fake_mise()
    log = Path.join(root, "release.log")

    seed_ready_release(root)

    {out, 0} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_RELEASE_LOG", log},
        {"TMUX", nil}
      ])

    refute out =~ "rebuilding"
    refute File.exists?(log)
  end

  test "the deferred rebuild reports failure so restart can refuse to start" do
    root = fake_repo()
    mise = fake_mise()

    {out, code} =
      run_shim(["__ensure-build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
        {"TMUX", nil}
      ])

    assert code == 9
    assert out =~ "aiur release rebuild failed"
  end

  test "--debug sets AIUR_DEBUG and is consumed, not forwarded to the engine" do
    root = fake_repo()

    {out, 0} =
      run_shim(["--debug", "status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: status"
    refute out =~ "--debug"
    assert out =~ "AIUR_DEBUG: 1"
  end

  test "init --force forwards --force to the engine" do
    root = fake_repo()

    {out, 0} =
      run_shim(["init", "--force"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: init --force"
  end

  test "--clear without --debug is rejected" do
    root = fake_repo()

    {out, code} =
      run_shim(["--clear"], [{"AIUR_REPO_ROOT", root}, {"AIUR_SKIP_BUILD", "1"}, {"TMUX", nil}])

    assert code == 64
    assert out =~ "--clear requires --debug"
  end

  test "--debug --clear wipes the logs root then execs the engine" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()

    {out, 0} =
      run_shim(["--debug", "--clear"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil},
        {"HOME", home}
      ])

    refute File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "AIUR_DEBUG: 1"
    assert out =~ "ENGINE_ARGS:"
  end

  test "--test resets the single sandbox ticket then runs, stripping the flag" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()

    {out, 0} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise}
      ])

    # Sandbox reset went through mise as a single-ticket, forced reset.
    assert out =~ "mix aiur.test.reset"
    assert out =~ "--single"
    # --test is consumed by the shim, never handed to the engine/release.
    refute out =~ "ENGINE_ARGS: --test"
    # Operator runs outside an agent workspace keep the real home-log clear and
    # never enter the agent IR sandbox branch.
    refute File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    refute out =~ "agent IR sandbox"
  end

  test "--test3 resets the blocker sandbox then runs, stripping the flag" do
    root = fake_repo()
    home = sandbox_home()
    mise = fake_mise()

    {out, 0} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise}
      ])

    assert out =~ "mix aiur.test.reset"
    assert out =~ "--allow-remote"
    refute out =~ "--single"
    refute out =~ "ENGINE_ARGS: --test3"
    refute File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    refute out =~ "agent IR sandbox"
  end

  test "agent workspace --test is blocked before reset, clear, stop, or launch" do
    root = fake_agent_repo(334)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root},
        {"AIUR_OPENCODE_BRIDGE_PORT", nil}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    assert out =~ "workspace marker: #{root}"
    assert out =~ "mutate the live dogfood backlog"
    assert out =~ "do not retry from a copied /tmp harness, clone, or alternate checkout"
    refute out =~ "agent IR sandbox"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    refute File.exists?(trace)
  end

  test "agent workspace non-test launch leaves bridge port to runtime selection" do
    root = fake_agent_repo(337)
    trace = engine_trace(root)
    mise = fake_mise()

    {out, 0} =
      run_shim(["--bg", "--debug"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    trace_out = File.read!(trace)

    assert out =~ "agent IR sandbox: #{Path.join(root, ".aiur-agent-ir")}"
    assert out =~ "AIUR_AGENT_IR_SANDBOX: 1"
    assert out =~ "AIUR_OPENCODE_BRIDGE_PORT: "
    refute out =~ ~r/AIUR_OPENCODE_BRIDGE_PORT: \d+/
    assert trace_out =~ "ENGINE_ARGS: --bg"
    assert trace_out =~ "AIUR_OPENCODE_BRIDGE_PORT: "
    refute trace_out =~ ~r/AIUR_OPENCODE_BRIDGE_PORT: \d+/
  end

  test "agent workspace --test remains blocked with a caller-supplied port" do
    root = fake_agent_repo(335)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test", "--port", "7000"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    refute out =~ "ENGINE_ARGS:"
    refute out =~ "mix aiur.test.reset"
    refute File.exists?(trace)
  end

  test "--port with no value is rejected before any side effect" do
    root = fake_agent_repo(336)
    home = sandbox_home()
    mise = fake_mise()

    {out, code} =
      run_shim(["--test", "--port"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    assert code == 64
    assert out =~ "--port requires a value"
    refute out =~ "mix aiur.test.reset"
    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
  end

  test "agent workspace --test3 detection falls back to AIUR_REPO_ROOT path without env marker" do
    root = fake_agent_repo(376)
    home = sandbox_home()
    mise = fake_mise()
    trace = engine_trace(root)

    {out, 64} =
      run_shim(["--test3"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_AGENT_WORKSPACE", nil}
      ])

    assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    assert out =~ "workspace marker: #{root}"
    assert out =~ "manual --test runs are blocked inside agent workspaces"
    refute out =~ "MISE_AIUR_AGENT_IR_SANDBOX: 1"
    refute out =~ "mix aiur.test.reset"
    refute out =~ "ENGINE_ARGS:"
    refute File.exists?(trace)
  end

  test "agent workspace non-test detection falls back to PWD and roots sandbox there" do
    root = fake_repo()
    # Per-run unique id under `aiur-workspaces` so concurrent test runs that
    # share `/tmp` (e.g. two CI jobs on one self-hosted runner, or this
    # `async: true` module's two PWD-fallback tests) can't collide on a fixed
    # path. A sibling run's `rm_rf` would otherwise yank the dir out from under
    # another run's cwd and surface as `MatchError {:error, :enoent}`.
    pwd = Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", "482-#{System.unique_integer([:positive])}"])
    home = sandbox_home()
    mise = fake_mise()

    File.mkdir_p!(pwd)

    try do
      expected_pwd = File.cd!(pwd, &File.cwd!/0)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", root},
            {"AIUR_SKIP_BUILD", "1"},
            {"TMUX", nil},
            {"HOME", home},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_AGENT_WORKSPACE", nil}
          ],
          cd: pwd
        )

      sandbox_root = Path.join(expected_pwd, ".aiur-agent-ir")

      assert out =~ "workspace marker: #{expected_pwd}"
      assert out =~ "agent IR sandbox: #{sandbox_root}"
      assert out =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
      assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    after
      File.rm_rf(pwd)
    end
  end

  test "agent workspace --test detection falls back to PWD and blocks before sandboxing" do
    root = fake_repo()
    # Per-run unique id under `aiur-workspaces` (see the sibling test above) to
    # keep concurrent runs sharing `/tmp` from colliding on a fixed path.
    pwd = Path.join([System.tmp_dir!(), "aiur-workspaces", "repo", "483-#{System.unique_integer([:positive])}"])
    home = sandbox_home()
    mise = fake_mise()

    File.mkdir_p!(pwd)

    try do
      expected_pwd = File.cd!(pwd, &File.cwd!/0)

      {out, 64} =
        run_shim(
          ["--test"],
          [
            {"AIUR_REPO_ROOT", root},
            {"AIUR_SKIP_BUILD", "1"},
            {"TMUX", nil},
            {"HOME", home},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_AGENT_WORKSPACE", nil}
          ],
          cd: pwd
        )

      assert out =~ "workspace marker: #{expected_pwd}"
      assert out =~ "manual --test runs are blocked inside agent workspaces"
      refute out =~ "agent IR sandbox"
      refute out =~ "mix aiur.test.reset"
      refute out =~ "ENGINE_ARGS:"
      assert File.exists?(Path.join([home, ".aiur", "logs", "old-session"]))
    after
      File.rm_rf(pwd)
    end
  end

  test "agent workspace stop targets the local IR sandbox identity" do
    root = fake_agent_repo(482)
    home = sandbox_home()
    trace = engine_trace(root)

    {out, 0} =
      run_shim(["stop"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_ENGINE_TRACE", trace},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil},
        {"HOME", home},
        {"AIUR_AGENT_WORKSPACE", root}
      ])

    sandbox_root = Path.join(root, ".aiur-agent-ir")

    assert out =~ "agent IR sandbox: #{sandbox_root}"
    assert out =~ "ENGINE_ARGS: stop"
    assert out =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    assert out =~ "XDG_RUNTIME_DIR: #{sandbox_root}/runtime"
    assert File.read!(trace) =~ "AIUR_BG_STATE_DIR: #{sandbox_root}/state"
    refute out =~ "ENGINE_ARGS: --port 0"
  end

  # --- checkout targeting -----------------------------------------------------
  # The shim resolves its target from its own path, so a globally symlinked
  # `aiurdev` invoked inside a different checkout used to compile into, and boot,
  # the symlink's repo — reporting success the whole way. These pin the refusal
  # and, just as importantly, the cases that must keep working.

  describe "checkout targeting" do
    test "refuses to build the symlink's checkout while standing in another one" do
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()
      log = Path.join(checkout_a, "release.log")

      {out, code} =
        run_shim(
          ["build"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_FAKE_MISE_RELEASE_LOG", log},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert code == 64
      assert out =~ "would target a different checkout"
      assert out =~ "you are in    : #{physical(checkout_b)}"
      assert out =~ "would target  : #{physical(checkout_a)}"
      assert out =~ "#{physical(checkout_b)}/scripts/aiurdev build"
      assert out =~ "AIUR_REPO_ROOT=#{physical(checkout_a)} aiurdev build"
      # The refusal has to come before the build, not after it.
      refute File.exists?(log)
      refute File.exists?(release_stamp_path(checkout_a))
    end

    test "refuses to restart the symlink's checkout while standing in another one" do
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      trace = engine_trace(checkout_a)

      seed_ready_release(checkout_a)

      {out, code} =
        run_shim(
          ["restart"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_ENGINE_TRACE", trace},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert code == 64
      assert out =~ "would target a different checkout"
      # Nothing reached the engine, so nothing was stopped: a refusal must not
      # cost the operator a running daemon.
      refute out =~ "ENGINE_ARGS:"
      refute File.exists?(trace)
    end

    test "an explicit AIUR_REPO_ROOT declares the target and is honored" do
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["restart"],
          [
            {"AIUR_REPO_ROOT", checkout_a},
            {"AIUR_SKIP_BUILD", "1"},
            {"AIUR_MISE_BIN", mise},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: restart"
      assert out =~ "RELEASE_DIR: #{checkout_a}/src/_build/dev/rel/aiur"
    end

    test "a trailing slash or symlinked AIUR_REPO_ROOT is still recognized as the target" do
      # The comparisons against it are physical-path comparisons; a raw value
      # would fail them and silently switch provenance off on a valid root.
      {checkout_a, shim_a} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", checkout_a <> "/"},
            {"AIUR_SKIP_BUILD", "1"},
            {"AIUR_MISE_BIN", mise},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_a
        )

      assert out =~ "RELEASE_DIR: #{physical(checkout_a)}/src/_build/dev/rel/aiur"
    end

    test "an executor RPC from another checkout reaches the daemon without building it" do
      # `executor-answer` is the only way to unblock a decision-paused agent, and
      # it is not on the pure-control list, so before this it force-built the
      # symlink's checkout on the way through. Refusing it instead would trade a
      # build nobody asked for against a fleet nobody can answer -- so it runs,
      # says which checkout it is speaking through, and builds nothing there.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()
      log = Path.join(checkout_a, "release.log")

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["executor-answer", "d-1"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_FAKE_MISE_RELEASE_LOG", log},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: executor-answer d-1"
      assert out =~ "speaking through #{physical(checkout_a)}"
      assert out =~ "#{physical(checkout_b)}/scripts/aiurdev"
      refute out =~ "rebuilding"
      refute File.exists?(log)
    end

    test "watch from another checkout does not force-build that checkout" do
      # `watch` is deliberately not a pure control command, so it reaches the
      # build path -- and it is the Executor's standing loop, i.e. the highest
      # frequency way to rewrite a foreign release under a live daemon.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()
      log = Path.join(checkout_a, "release.log")

      seed_ready_release(checkout_a)
      # Make the sources newer than the release: without the divergence rule this
      # is exactly the state that triggers a rebuild.
      File.mkdir_p!(Path.join([checkout_a, "src", "lib"]))
      newer = Path.join([checkout_a, "src", "lib", "newer.ex"])
      File.write!(newer, "# stale after release\n")
      File.touch!(Path.join([checkout_a, "src", "bin", "aiur"]), {{2020, 1, 1}, {0, 0, 0}})
      File.touch!(newer, {{2030, 1, 1}, {0, 0, 0}})

      {out, 0} =
        run_shim(
          ["watch"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_FAKE_MISE_RELEASE_LOG", log},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: watch"
      refute out =~ "rebuilding"
      refute File.exists?(log)
    end

    test "a control command is refused when the other checkout has no release to reuse" do
      # Reusing the other checkout's release is only harmless while there is one.
      # With none, reaching its daemon would compile one there, which is the same
      # foreign build the guard exists to stop.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()
      log = Path.join(checkout_a, "release.log")

      {out, code} =
        run_shim(
          ["status"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_FAKE_MISE_RELEASE_LOG", log},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_b
        )

      assert code == 64
      assert out =~ "cannot run this against #{physical(checkout_a)} without building it"
      assert out =~ "AIUR_REPO_ROOT=#{physical(checkout_a)} aiurdev build"
      refute out =~ "ENGINE_ARGS:"
      refute File.exists?(log)
    end

    test "an agent workspace clone is refused a run against the operator's checkout" do
      # Agent workspaces are full clones, so they carry all three markers. An
      # agent invoking a globally symlinked aiurdev from its workspace would
      # otherwise build and boot the Executor's checkout -- cross-contamination
      # between a ticket's tree and the operator's.
      {checkout_a, shim_a} = fake_checkout()

      workspace =
        Path.join([
          System.tmp_dir!(),
          "aiur-workspaces",
          "repo",
          "9001-#{System.unique_integer([:positive])}"
        ])

      {workspace, _shim_w} = fake_checkout(workspace)
      link = global_shim(shim_a)
      home = sandbox_home()

      seed_ready_release(checkout_a)

      {out, code} =
        run_shim(
          ["--bg"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}, {"HOME", home}, {"AIUR_AGENT_WORKSPACE", nil}],
          script: link,
          cd: workspace
        )

      assert code == 64
      assert out =~ "would target a different checkout"
      assert out =~ "#{physical(workspace)}/scripts/aiurdev"
      refute out =~ "ENGINE_ARGS:"
    end

    test "control commands from another checkout still reach the daemon" do
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)

      seed_ready_release(checkout_a)

      # `status` neither builds nor boots — it queries the one global daemon
      # through whatever complete release is at hand, so there is no divergence
      # to refuse and a refusal here would only be noise.
      {out, 0} =
        run_shim(
          ["status"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: status"
    end

    test "a dev flag before a control command does not make it look like a run" do
      # The shim consumes --debug before dispatch, so the command the engine
      # sees is `status` -- classifying on the raw first argument would refuse a
      # control command that has no build to divert.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)
      home = sandbox_home()

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["--debug", "status"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}, {"HOME", home}],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: status"
      assert out =~ "AIUR_DEBUG: 1"
    end

    test "a symlinked shim still runs from a directory in no checkout at all" do
      {checkout_a, shim_a} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_SKIP_BUILD", "1"},
            {"AIUR_MISE_BIN", mise},
            {"TMUX", nil}
          ],
          script: link,
          cd: System.tmp_dir!()
        )

      assert out =~ "ENGINE_ARGS: --bg"
      assert out =~ "RELEASE_DIR: #{checkout_a}/src/_build/dev/rel/aiur"
    end

    test "a symlinked shim invoked inside its own checkout is not a divergence" do
      {checkout_a, shim_a} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_SKIP_BUILD", "1"},
            {"AIUR_MISE_BIN", mise},
            {"TMUX", nil}
          ],
          script: link,
          cd: checkout_a
        )

      assert out =~ "ENGINE_ARGS: --bg"
    end

    test "a cwd inside a partial tree is not mistaken for a checkout" do
      {checkout_a, shim_a} = fake_checkout()
      link = global_shim(shim_a)
      mise = fake_mise()
      # A repo-shaped directory missing src/mix.exs is not an aiur checkout, and
      # refusing there would block a legitimate run for nothing.
      partial = Path.join(System.tmp_dir!(), "aiurdev-partial-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([partial, "packaging", "npm", "aiur-cli", "libexec"]))
      File.mkdir_p!(Path.join(partial, "scripts"))
      File.write!(Path.join([partial, "scripts", "aiurdev"]), "")
      File.write!(Path.join([partial, "packaging", "npm", "aiur-cli", "libexec", "aiur-engine.sh"]), "")
      on_exit(fn -> File.rm_rf!(partial) end)

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["--bg"],
          [
            {"AIUR_REPO_ROOT", nil},
            {"AIUR_SKIP_BUILD", "1"},
            {"AIUR_MISE_BIN", mise},
            {"TMUX", nil}
          ],
          script: link,
          cd: partial
        )

      assert out =~ "ENGINE_ARGS: --bg"
    end
  end

  # --- release provenance -----------------------------------------------------

  describe "release provenance" do
    test "a completed build stamps the release with its repo root and source sha" do
      root = fake_repo()
      mise = fake_mise()

      {_out, 0} =
        run_shim(["build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"TMUX", nil}
        ])

      stamp = File.read!(release_stamp_path(root))

      assert stamp =~ "repo_root=#{root}"
      # Outside a git work tree there is no commit to record; the field is still
      # present so a reader never has to guess whether stamping ran.
      assert stamp =~ "source_sha=unknown"
      assert stamp =~ ~r/built_at=\d{4}-\d{2}-\d{2}T/
    end

    test "a repo root nested inside another repository is not stamped with that repo's commit" do
      # `git -C` walks up to the nearest enclosing repository. Stamping the outer
      # repo's HEAD would claim provenance for a tree nobody built — and would
      # then compare that borrowed SHA against itself on every later launch.
      outer = Path.join(System.tmp_dir!(), "aiurdev-outer-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outer)
      on_exit(fn -> File.rm_rf!(outer) end)
      init_git_repo(outer)

      root = fake_repo(Path.join(outer, "inner"))
      mise = fake_mise()

      {_out, 0} =
        run_shim(["build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"TMUX", nil}
        ])

      stamp = File.read!(release_stamp_path(root))

      assert stamp =~ "source_sha=unknown"
      refute stamp =~ git_head(outer)
    end

    test "a ready release with no stamp is rebuilt rather than trusted" do
      root = fake_repo()
      mise = fake_mise()
      log = Path.join(root, "release.log")

      seed_ready_release(root)
      File.rm!(release_stamp_path(root))

      {out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      assert out =~ "rebuilding"
      assert File.exists?(log)
    end

    test "a ready release built from another commit is rebuilt even when no source is newer" do
      root = fake_repo()
      mise = fake_mise()
      log = Path.join(root, "release.log")

      init_git_repo(root)
      seed_ready_release(root)
      # Every source file predates the release, so the mtime sweep alone would
      # call this current — which is how a `git switch` ships the old build.
      stamp_release(root, String.duplicate("a", 40))

      {out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      assert out =~ "rebuilding"
      assert File.exists?(log)
      assert File.read!(release_stamp_path(root)) =~ "source_sha=#{git_head(root)}"
    end

    test "a ready release stamped with the checked-out commit is left alone" do
      root = fake_repo()
      mise = fake_mise()
      log = Path.join(root, "release.log")

      init_git_repo(root)
      seed_ready_release(root)
      stamp_release(root, git_head(root))

      {out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      refute out =~ "rebuilding"
      refute File.exists?(log)
    end

    test "AIUR_SKIP_BUILD leaves restart a plain bounce instead of an unverifiable one" do
      # Wiring in a rebuild that will decline to build would stop the daemon and
      # then hand the engine a success it cannot match to the release on disk --
      # exit 70 with the fleet down, over a build the operator asked to skip.
      root = fake_repo()
      mise = fake_mise()

      seed_ready_release(root)

      {out, 0} =
        run_shim(["restart"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_SKIP_BUILD", "1"},
          {"AIUR_MISE_BIN", mise},
          {"TMUX", nil}
        ])

      assert out =~ "ENGINE_ARGS: restart"
      assert out =~ ~r/^RESTART_BUILD_CMD: *$/m
    end

    test "a stamp from another commit converges on one rebuild rather than staying unknown" do
      # A release stamped `unknown` on a host where git now answers must not stay
      # unknown forever: `restart` compares the receipt SHA against the stamp, so
      # a permanently-unknown stamp is a permanently unverifiable restart.
      root = fake_repo()
      mise = fake_mise()
      log = Path.join(root, "release.log")

      init_git_repo(root)
      seed_ready_release(root)
      stamp_release(root, "unknown")

      {out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_RELEASE_LOG", log},
          {"TMUX", nil}
        ])

      assert out =~ "rebuilding"
      assert File.read!(release_stamp_path(root)) =~ "source_sha=#{git_head(root)}"
    end

    test "the deferred rebuild leaves a receipt naming the release it vouches for" do
      root = fake_repo()
      mise = fake_mise()
      receipt = Path.join(root, "receipt")

      seed_ready_release(root)

      {_out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_RESTART_BUILD_RECEIPT", receipt},
          {"TMUX", nil}
        ])

      contents = File.read!(receipt)

      assert contents =~ "release_dir=#{root}/src/_build/dev/rel/aiur"
      assert contents =~ "repo_root=#{root}"
      assert contents =~ "source_sha=unknown"
    end

    test "a failed rebuild leaves no receipt for restart to trust" do
      root = fake_repo()
      mise = fake_mise()
      receipt = Path.join(root, "receipt")

      {_out, 9} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
          {"AIUR_RESTART_BUILD_RECEIPT", receipt},
          {"TMUX", nil}
        ])

      refute File.exists?(receipt)
    end
  end
end
