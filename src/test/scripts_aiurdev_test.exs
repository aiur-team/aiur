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
            ;;
          release)
            if [ -n "${AIUR_FAKE_MISE_RELEASE_LOG:-}" ]; then
              echo "release start $$" >> "$AIUR_FAKE_MISE_RELEASE_LOG"
            fi
            if [ -n "${AIUR_FAKE_MISE_RELEASE_SLEEP:-}" ]; then
              sleep "$AIUR_FAKE_MISE_RELEASE_SLEEP"
            fi
            mkdir -p bin _build/dev/rel/aiur/bin _build/dev/rel/aiur/releases/0.0.3 _build/dev/rel/aiur/erts-16.4/bin
            echo '#!/usr/bin/env bash' > bin/aiur
            echo '#!/usr/bin/env bash' > _build/dev/rel/aiur/bin/aiur
            echo '#!/usr/bin/env bash' > _build/dev/rel/aiur/erts-16.4/bin/epmd
            chmod +x bin/aiur _build/dev/rel/aiur/bin/aiur _build/dev/rel/aiur/erts-16.4/bin/epmd
            echo '16.4 0.0.3' > _build/dev/rel/aiur/releases/start_erl.data
            : > _build/dev/rel/aiur/releases/0.0.3/start_clean.boot
            : > _build/dev/rel/aiur/releases/0.0.3/vm.args
            : > _build/dev/rel/aiur/releases/0.0.3/sys.config
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

    System.cmd("bash", [@script | args],
      env: base_env ++ env,
      cd: Keyword.get(opts, :cd, System.tmp_dir!()),
      stderr_to_stdout: true
    )
  end

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

    {out, 0} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: --bg"
    assert out =~ "OPENCODE_PATH: #{mise}.opencode/opencode"
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

    {out, 64} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", Path.join(root, "missing-mise")},
        {"TMUX", nil}
      ])

    assert out =~ "mise not found"
    refute out =~ "ENGINE_ARGS:"
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
end
