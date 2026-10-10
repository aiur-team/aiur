defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "resolves a per-instance keyed identity" do
    # Runs inside an aiur project (this repo has .aiur/config), so the node name is
    # keyed by the project root — two instances for the same user can't collide (#431).
    home = Aiur.TestSupport.tmp_root!("aiur-identity-home")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    id = identity([{"HOME", home}, {"XDG_CONFIG_HOME", nil}])

    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
    assert id["AIUR_INSTANCE_KEY"] =~ ~r/\A[0-9a-f]{1,12}\z/
    assert id["AIUR_BG_STATE_DIR"] == Path.join(home, ".config/aiur")
    assert id["AIUR_COOKIE_FILE"] == Path.join(home, ".config/aiur/cookie")
  end

  test "the state dir is redirectable so tests need not touch ~/.config/aiur" do
    id = identity([{"AIUR_BG_STATE_DIR", "/tmp/aiur-test-state"}])

    assert id["AIUR_BG_STATE_DIR"] == "/tmp/aiur-test-state"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/aiur-test-state/cookie"
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
  end

  test "tmux pane launcher preserves agent-local opencode bridge port override" do
    assert Aiur.EngineSource.text() =~ "AIUR_OPENCODE_BRIDGE_PORT"
  end

  test "engine exports the effective soft nofile limit after raising it" do
    {out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_NOFILE_SOFT_LIMIT" = "$(ulimit -Sn)" && echo NOFILE_MATCH|,
        [{"AIUR_NOFILE_SOFT_LIMIT", "1"}]
      )

    assert out =~ "NOFILE_MATCH"
  end

  test "engine captures a best-effort operator pid and preserves an explicit root" do
    {out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_OPERATOR_PID" = "$PPID" && echo PARENT_MATCH|,
        [{"AIUR_OPERATOR_PID", "invalid"}]
      )

    assert out =~ "PARENT_MATCH"

    {override_out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_OPERATOR_PID" = "4242" && echo OVERRIDE_KEPT|,
        [{"AIUR_OPERATOR_PID", "4242"}]
      )

    assert override_out =~ "OVERRIDE_KEPT"
  end

  test "tmux pane launcher re-exports resource attribution inputs" do
    engine = Aiur.EngineSource.text()

    assert engine =~
             "AIUR_OPERATOR_PID AIUR_LAUNCHER_PID AIUR_NOFILE_SOFT_LIMIT ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS"
  end

  test "fresh foreground pane receives its launcher pid and tmux bridge helper" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-launcher-watchdog")
    pane_copy = Path.join(tmp, "pane.sh")
    session = Path.join(tmp, "session")
    helper_option = Path.join(tmp, "ctrlc-option")
    File.mkdir_p!(tmp)

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          cp "#{tmp}"/aiur-pane.* "#{pane_copy}"
          touch "#{session}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{session}" ]; exit $? ;;
        *" set-option -g @aiur_ctrlc "*) echo "$*" > "#{helper_option}"; exit 0 ;;
        *" attach "*) exit 0 ;;
        *" kill-session "*) rm -f "#{session}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() { printf '424242\\n'; }
    reap_aiur_agents() { :; }
    kill_beams_matching() { :; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    echo "LAUNCHER_PID=$$"
    run_session foreground --no-dashboard
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"TMP_ROOT", tmp},
        {"XDG_RUNTIME_DIR", tmp},
        {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"},
        {"AIUR_LAUNCHER_PID", "999999"}
      ])

    [_, launcher_pid] = Regex.run(~r/LAUNCHER_PID=(\d+)/, out)
    assert File.read!(pane_copy) =~ "export AIUR_LAUNCHER_PID=#{launcher_pid}\n"
    refute File.read!(pane_copy) =~ "export AIUR_LAUNCHER_PID=999999\n"
    assert File.read!(helper_option) =~ "set-option -g @aiur_ctrlc #{Path.dirname(engine())}/aiur-pane-ctrlc"
  end

  test "generated tmux pane launcher gives the inner daemon the pinned scope and instance key" do
    rel = fake_release()
    state = tmp_state()
    tmp = Aiur.TestSupport.tmp_root!("aiur-test-scope-pane")
    pane_copy = Path.join(tmp, "pane.sh")
    session = Path.join(tmp, "session")
    File.mkdir_p!(tmp)

    File.write!(
      Path.join([rel, "releases", "0.1.1", "elixir"]),
      ~S|#!/usr/bin/env bash
printf 'INNER_SCOPE=%s\n' "${AIUR_DEV_TEST_TICKET_IDS:-missing}"
printf 'INNER_KEY=%s\n' "${AIUR_INSTANCE_KEY:-missing}"
|
    )

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) cp "#{tmp}"/aiur-pane.* "#{pane_copy}"; touch "#{session}"; exit 0 ;;
        *" has-session "*) [ -f "#{session}" ]; exit $? ;;
        *" attach "*) exit 0 ;;
        *" kill-session "*) rm -f "#{session}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(tmp)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() { printf '424242\n'; }
    reap_aiur_agents() { :; }
    kill_beams_matching() { :; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    run_session foreground --no-dashboard
    """

    {_out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_DEV_TEST_TICKET_IDS", "99,100,101"},
        {"AIUR_INSTANCE_KEY", "0123456789"},
        {"TMP_ROOT", tmp},
        {"XDG_RUNTIME_DIR", tmp},
        {"PATH", "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"}
      ])

    {inner, 0} = System.cmd("bash", [pane_copy], env: [{"AIUR_DEV_TEST_TICKET_IDS", "777"}, {"AIUR_INSTANCE_KEY", "aaaaaaaaaa"}])
    assert inner =~ "INNER_SCOPE=99,100,101\n"
    assert inner =~ "INNER_KEY=0123456789\n"
  end

  test "sourced-engine runs isolate the node identity so reaps can't hit a live host node" do
    # The engine's launch/stop paths reap any BEAM holding their node name
    # (`kill_beams_matching "-name $AIUR_RELEASE_NODE"`). When `mix test` sources
    # the engine on the same host/project as a live aiur, an un-isolated run
    # resolves the SAME node name and reaps the operator's BEAM mid-run. Guard:
    # sourced-engine runs must resolve a unique node, never the host's real one.
    {real, 0} =
      System.cmd(engine(), ["__identity"], env: [{"AIUR_ENGINE", engine()}], stderr_to_stdout: true)

    real_node =
      real
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["AIUR_RELEASE_NODE", v] -> v
          _ -> nil
        end
      end)

    {sourced, 0} =
      run_sourced_engine(~s|aiur_resolve_identity; printf '%s' "$AIUR_RELEASE_NODE"|, [])

    refute sourced == real_node
    assert sourced =~ ~r/\Aaiur-enginetest-\d+@127\.0\.0\.1\z/
  end

  # A minimal stub release: start_erl.data + a fake `elixir` that echoes its args
  # so dispatch/boot-shape can be asserted without a real BEAM.

  test "fake release roots include the host process identity" do
    assert Path.basename(fake_release()) =~ "aiur-engine-rel-#{System.pid()}-"
  end

  test "every help alias prints usage and exits 0" do
    for flag <- ["help", "-h", "-help", "--h", "--help"] do
      {out, code} = run_engine([flag], [])
      assert code == 0, "#{flag} should exit 0"
      assert out =~ "Usage: aiur", "#{flag} should print usage"
      assert out =~ "start or attach", "#{flag} should explain bare attach behavior"
    end
  end

  test "run refuses a legacy config before release startup" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-legacy-config")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(engine(), [],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ ".aiurconfig is no longer supported"
    assert out =~ ".aiur/config"
    assert out =~ "relative prompt_file and hooks_file paths"
    refute out =~ "release not found"
  end

  test "legacy preflight checks the global fallback but canonical config wins" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-global-legacy-config")
    home = Path.join(root, "home")
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(home, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"HOME", home},
      {"AIUR_REPO_ROOT", nil},
      {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
      {"USER", "tester"}
    ]

    {legacy_out, 1} = System.cmd(engine(), [], cd: repo, env: env, stderr_to_stdout: true)
    assert legacy_out =~ ".aiurconfig is no longer supported"

    File.mkdir_p!(Path.join(home, ".aiur"))
    File.write!(Path.join([home, ".aiur", "config"]), "tracker:\n  kind: memory\n")

    {canonical_out, 1} = System.cmd(engine(), [], cd: repo, env: env, stderr_to_stdout: true)
    refute canonical_out =~ ".aiurconfig is no longer supported"
    assert canonical_out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "run refuses an explicit named legacy config before release startup" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-explicit-legacy-config")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    legacy = Path.join(repo, "portable.aiurconfig")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(legacy, "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(engine(), [legacy],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ "portable.aiurconfig is no longer supported"
    assert out =~ "portable.yaml"
    refute out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "legacy preflight does not mistake option values for config paths" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-legacy-option-value")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(repo, ".aiur"))
    File.write!(Path.join([repo, ".aiur", "config"]), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(engine(), ["--bg", "--logs-root", Path.join(root, "archive.aiurconfig")],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    refute out =~ "aiurconfig is no longer supported"
    refute out =~ "basename:"
    assert out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "explicit repo root still checks the global legacy fallback" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-explicit-root-global-legacy")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(home, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(engine(), [],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", repo},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ Path.join(home, ".aiurconfig")
    assert out =~ "is no longer supported"
    refute out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "an explicit canonical config wins over an ambient legacy file" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-explicit-canonical-config")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    canonical = Path.join(root, "portable.yaml")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    File.write!(canonical, "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(engine(), [canonical],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", repo},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    refute out =~ "aiurconfig is no longer supported"
    assert out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "argument terminator preserves dashed explicit config precedence" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-dashed-explicit-config")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    File.write!(Path.join(repo, "--portable.yaml"), "tracker:\n  kind: memory\n")
    File.write!(Path.join(repo, "--portable.aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"HOME", home},
      {"AIUR_REPO_ROOT", repo},
      {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
      {"USER", "tester"}
    ]

    {canonical_out, 1} = System.cmd(engine(), ["--", "--portable.yaml"], cd: repo, env: env, stderr_to_stdout: true)
    refute canonical_out =~ "aiurconfig is no longer supported"
    assert canonical_out =~ "AIUR_RELEASE_DIR does not exist"

    {legacy_out, 1} = System.cmd(engine(), ["--", "--portable.aiurconfig"], cd: repo, env: env, stderr_to_stdout: true)
    assert legacy_out =~ "--portable.aiurconfig is no longer supported"
    assert legacy_out =~ "--portable.yaml"
    refute legacy_out =~ "basename:"
  end

  test "usage describes init and no longer lists sweep" do
    {out, 0} = run_engine(["--help"], [])
    assert out =~ ~r/aiur init \[--force\]\s+scaffold/
    assert out =~ "aiur --todo <ids...> [--only]"
    assert out =~ "aiur findings [--unfiled] [--slugs] [--scope aiur|repo]"
    assert out =~ "aiur findings --record <json> --repo <owner/repo>"
    assert out =~ "aiur findings --digest [--scope aiur|repo]"
    assert out =~ "aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]"
    assert out =~ "aiur asks [--open|--all] [--json]"
    assert out =~ "aiur run [--bg] [--no-dashboard] [--executor] [--debug]"
    assert out =~ "aiur --bg [--no-dashboard] [--executor] [--debug]"
    refute out =~ "sweep"
  end

  # #2717. `--message-id` names one send, so the retry the CLI prints after an
  # unknown outcome reaches the daemon with the same id.

  test "npm manifest ships every sourced engine module" do
    package_dir = Path.dirname(cli_package())
    files = cli_package() |> File.read!() |> Jason.decode!() |> Map.fetch!("files")
    shipped = Enum.flat_map(files, &Path.wildcard(Path.join(package_dir, &1)))

    {out, 0} = run_sourced_engine(~S(printf '%s\n' $AIUR_ENGINE_MODULES), [])
    sourced = out |> String.split() |> Enum.map(&Path.join(package_dir, "libexec/engine/#{&1}.sh"))

    assert Enum.sort(sourced) == Enum.sort(Path.wildcard(Path.join(package_dir, "libexec/engine/*.sh")))
    assert sourced -- shipped == []
  end

  test "a missing engine module aborts by path before any command runs" do
    root = Aiur.TestSupport.tmp_root!("aiur-engine-modules")
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp_r!(Path.dirname(engine()), root)
    File.rm!(Path.join(root, "engine/upgrade.sh"))

    {out, code} = System.cmd("bash", [Path.join(root, "aiur-engine.sh"), "--help"], stderr_to_stdout: true)

    assert code == 1
    assert out == "❌ missing engine module: #{root}/engine/upgrade.sh\n"
  end
end
