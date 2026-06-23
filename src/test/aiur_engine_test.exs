defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # Run the engine's `__identity` probe with a clean AIUR_* env plus the given
  # overrides, returning the resolved KEY=VALUE map.
  defp identity(overrides) do
    base = [
      {"USER", "tester"},
      {"AIUR_BG_STATE_DIR", nil},
      {"AIUR_SESSION_PREFIX", nil},
      {"AIUR_PROFILES_FILE", nil},
      {"AIUR_RELEASE_NODE", nil},
      {"AIUR_COOKIE_FILE", nil},
      {"AIUR_RELEASE_DIR", nil},
      {"AIUR_REPO_ROOT", nil},
      {"AIUR_INSTANCE_KEY", nil}
    ]

    env = base ++ overrides

    {out, 0} = System.cmd(@engine, ["__identity"], env: env, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "resolves a per-instance keyed identity" do
    # Runs inside an aiur project (this repo has .aiur/config), so the node name is
    # keyed by the project root — two instances for the same user can't collide (#431).
    id = identity([])

    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
    assert id["AIUR_INSTANCE_KEY"] =~ ~r/\A[0-9a-f]{1,12}\z/
    assert id["AIUR_BG_STATE_DIR"] =~ ~r{/\.config/aiur$}
    assert id["AIUR_COOKIE_FILE"] =~ ~r{/\.config/aiur/cookie$}
  end

  test "the state dir is redirectable so tests need not touch ~/.config/aiur" do
    id = identity([{"AIUR_BG_STATE_DIR", "/tmp/aiur-test-state"}])

    assert id["AIUR_BG_STATE_DIR"] == "/tmp/aiur-test-state"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/aiur-test-state/cookie"
    # the instance key is derived from the project root, not the state dir
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
  end

  # A minimal stub release: start_erl.data + a fake `elixir` that echoes its args
  # so dispatch/boot-shape can be asserted without a real BEAM.
  defp fake_release do
    dir = Path.join(System.tmp_dir!(), "aiur-engine-rel-#{System.unique_integer([:positive])}")
    vsn = Path.join([dir, "releases", "0.1.1"])
    File.mkdir_p!(vsn)
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "releases", "start_erl.data"]), "16.4 0.1.1\n")
    elixir = Path.join(vsn, "elixir")
    File.write!(elixir, "#!/usr/bin/env bash\necho \"ELIXIR_ARGS: $*\"\n")
    File.chmod!(elixir, 0o755)
    for f <- ["sys", "start_clean", "vm.args"], do: File.write!(Path.join(vsn, f), "")
    File.write!(Path.join([dir, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"BIN: $*\"\n")
    File.chmod!(Path.join([dir, "bin", "aiur"]), 0o755)
    dir
  end

  defp run_engine(args, env) do
    System.cmd(@engine, args, env: [{"USER", "tester"} | env], stderr_to_stdout: true)
  end

  test "every help alias prints usage and exits 0" do
    for flag <- ["help", "-h", "-help", "--h", "--help"] do
      {out, code} = run_engine([flag], [])
      assert code == 0, "#{flag} should exit 0"
      assert out =~ "Usage: aiur", "#{flag} should print usage"
    end
  end

  test "usage describes init and no longer lists sweep" do
    {out, 0} = run_engine(["--help"], [])
    assert out =~ ~r/aiur init \[--force\]\s+scaffold/
    refute out =~ "sweep"
  end

  test "--version is distribution-free so it never collides with a running node" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["--version"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    # Runs through the start_clean `elixir --eval` path (like init), never the
    # distributed release start script — so it claims no node name.
    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "--eval"
    refute out =~ "--name"
    refute out =~ "BIN:"
  end

  test "kill_beams_matching reaps a node-name holder from any release dir" do
    # A unified node name means an orphaned BEAM from a different release dir
    # still blocks a launch; the reaper must match by `-name`, not release path.
    marker = "-name aiur-killtest-#{System.unique_integer([:positive])}@127.0.0.1"
    on_exit(fn -> System.cmd("pkill", ["-f", marker], stderr_to_stdout: true) end)

    # Run from a file so the marker isn't in the launching shell's own argv
    # (which `pgrep -f` would otherwise match and reap).
    script = """
    source #{@engine}
    set +e
    bash -c 'exec -a "beam.smp #{marker} extra" sleep 10' >/dev/null 2>&1 &
    for _ in $(seq 1 20); do pgrep -f -- '#{marker}' >/dev/null && break; sleep 0.1; done
    kill_beams_matching '#{marker}'
    pgrep -f -- '#{marker}' >/dev/null && echo STILL_ALIVE || echo REAPED
    """

    path = Path.join(System.tmp_dir!(), "aiur-reap-#{System.unique_integer([:positive])}.sh")
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    {out, _} = System.cmd("bash", [path], stderr_to_stdout: true)
    assert out =~ "REAPED"
  end

  test "load_dotenv reads ./.env, strips quotes, and lets shell exports win" do
    dir = Path.join(System.tmp_dir!(), "aiur-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "# token\nGITHUB_TOKEN=fromfile\nFOO=\"bar baz\"\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src = "cd #{dir}; source #{@engine}; load_dotenv; echo \"TOK=$GITHUB_TOKEN|FOO=$FOO\""

    {out, 0} =
      System.cmd("bash", ["-c", src],
        env: [{"GITHUB_TOKEN", nil}, {"FOO", nil}],
        stderr_to_stdout: true
      )

    assert out =~ "TOK=fromfile|FOO=bar baz"

    # A value already in the environment is never clobbered by the file.
    {out2, 0} = System.cmd("bash", ["-c", "export GITHUB_TOKEN=shell; #{src}"], stderr_to_stdout: true)
    assert out2 =~ "TOK=shell|"
  end

  test "an unknown command exits 64 with usage" do
    {out, code} = run_engine(["bogus-not-a-path"], [])
    assert code == 64
    assert out =~ "unknown command"
  end

  test "init boots interactively and distribution-free (no --name/--cookie)" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["init"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "--eval"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "--cookie"
  end

  # Lifecycle commands generate + validate a cookie, whose owner must equal
  # $USER, so these run as the real user (only the state dir is redirected).
  defp run_engine_real(args, env) do
    System.cmd(@engine, args, env: env, stderr_to_stdout: true)
  end

  defp tmp_state, do: Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

  test "pause without targets exits 64 with guidance" do
    {out, code} = run_engine_real(["pause"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "expects issue IDs or --all"
  end

  test "pause/resume RPC the AgentControlCLI expression into the node" do
    rel = fake_release()
    state = tmp_state()

    {paused, _} = run_engine_real(["pause", "44,45"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert paused =~ ~s|Aiur.AgentControlCLI.pause(["44", "45"])|

    {resumed, _} = run_engine_real(["resume", "--all"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert resumed =~ "Aiur.AgentControlCLI.resume(:all)"
  end

  test "status RPCs the status expression" do
    rel = fake_release()
    {out, _} = run_engine_real(["status"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AgentControlCLI.status()"
  end

  test "message RPCs the message expression with base64-encoded text" do
    rel = fake_release()

    {out, _} =
      run_engine_real(
        ["message", "44", "ship it"],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    encoded = Base.encode64("ship it")
    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{encoded}"))|
  end

  test "message base64-transports hostile text so it cannot break the RPC expression" do
    rel = fake_release()
    # Quotes, backslash, Elixir interpolation, and a newline — the exact characters
    # the base64 hop exists to neutralize.
    hostile = ~s|say "hi" #{"\#{System.halt}"} \\o/| <> "\nline2"

    {out, _} =
      run_engine_real(
        ["message", "44", hostile],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{Base.encode64(hostile)}"))|
    # The raw text never reaches the expression un-encoded.
    refute out =~ ~s|say "hi"|
    refute out =~ "System.halt"
  end

  test "message without text exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "44"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message with a non-numeric issue id exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "abc", "hi"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message without an issue exits 64 with guidance" do
    {out, code} = run_engine_real(["message"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  # --- stale /tmp artifact reaping (#334) -------------------------------------
  #
  # The reaper only ever scans the temp roots TMPDIR / XDG_RUNTIME_DIR point at,
  # so each test redirects both at a throwaway mktemp dir — the real /tmp is never
  # touched. Old mtimes use `touch -t CCYYMMDDhhmm`, which both GNU and BSD touch
  # accept, so these run identically on Linux CI and macOS dev.

  test "sweep_stale_tmp_artifacts reaps stale known debris and spares live/fresh/non-matching" do
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-test.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"

    touch -t "$OLD" "$T/aiur-argv.STALE"
    touch "$T/aiur-argv.FRESH"
    mkdir -p "$T/aiur-rc"; touch "$T/aiur-rc/live.log"; touch -t "$OLD" "$T/aiur-rc"
    mkdir -p "$T/aiur-debug"; touch -t "$OLD" "$T/aiur-debug/old.log"; touch -t "$OLD" "$T/aiur-debug"
    mkdir -p "$T/aiur-pr123"; touch -t "$OLD" "$T/aiur-pr123/checkout"; touch -t "$OLD" "$T/aiur-pr123"
    mkdir -p "$T/aiur_workspaces/w"; touch -t "$OLD" "$T/aiur_workspaces/w/f"; touch -t "$OLD" "$T/aiur_workspaces"
    mkdir -p "$T/aiur100-hex"; touch -t "$OLD" "$T/aiur100-hex/c"; touch -t "$OLD" "$T/aiur100-hex"
    touch -t "$OLD" "$T/aiur-user-note.txt"
    touch -t "$OLD" "$T/aiur-4000000000-agents"
    sleep 30 & LIVE=$!
    touch -t "$OLD" "$T/aiur-$LIVE-agents"
    touch -t "$OLD" "$T/unrelated.txt"

    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=60 sweep_stale_tmp_artifacts

    chk(){ if [ "$2" = present ]; then [ -e "$T/$1" ] && echo "PASS $1" || echo "FAIL $1 expected-present"; else [ -e "$T/$1" ] && echo "FAIL $1 expected-gone" || echo "PASS $1"; fi; }
    chk aiur-argv.STALE gone
    chk aiur-argv.FRESH present
    chk aiur-rc present
    chk aiur-debug gone
    chk aiur-pr123 present
    chk aiur_workspaces present
    chk aiur100-hex present
    chk aiur-user-note.txt present
    chk aiur-4000000000-agents gone
    chk "aiur-$LIVE-agents" present
    chk unrelated.txt present
    kill "$LIVE" 2>/dev/null || true
    rm -rf "$T"
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, "fixture script aborted:\n#{out}"
    refute out =~ "FAIL", "unexpected reaper outcome:\n#{out}"

    # Each outcome asserted by name so a regression names exactly what drifted.
    for name <- ~w(aiur-argv.STALE aiur-argv.FRESH aiur-rc aiur-debug aiur_workspaces
                   aiur-pr123 aiur100-hex aiur-user-note.txt aiur-4000000000-agents
                   unrelated.txt) do
      assert out =~ "PASS #{name}", "missing PASS #{name} in:\n#{out}"
    end

    # The live-pid pidfile (name carries a runtime pid) was spared.
    assert out =~ ~r/PASS aiur-\d+-agents/
  end

  test "sweep_stale_tmp_artifacts default window spares artifacts younger than 24h" do
    # A 3-hour-old artifact must survive the conservative 1440-minute default —
    # this is the guard that a same-day dev/test run is never reaped out from under.
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-default.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.RECENT"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.RECENT" ] && echo "KEPT" || echo "GONE"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT"
    refute out =~ "GONE"
  end

  test "sweep_stale_tmp_artifacts is disabled by a 0 or non-numeric AIUR_TMP_REAP_MINUTES" do
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-off.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.STALE"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=0 sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-ZERO" || echo "GONE-ZERO"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=abc sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-NAN" || echo "GONE-NAN"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT-ZERO"
    assert out =~ "KEPT-NAN"
    refute out =~ "GONE"
  end
end
