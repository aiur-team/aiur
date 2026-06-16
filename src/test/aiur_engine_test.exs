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
      {"AIUR_RELEASE_DIR", nil}
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

  test "resolves the single aiur identity" do
    id = identity([])

    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
    assert id["AIUR_BG_STATE_DIR"] =~ ~r{/\.config/aiur$}
    assert id["AIUR_COOKIE_FILE"] =~ ~r{/\.config/aiur/cookie$}
  end

  test "the state dir is redirectable so tests need not touch ~/.config/aiur" do
    id = identity([{"AIUR_BG_STATE_DIR", "/tmp/aiur-test-state"}])

    assert id["AIUR_BG_STATE_DIR"] == "/tmp/aiur-test-state"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/aiur-test-state/cookie"
    # naming stays the fixed aiur identity regardless of state dir
    assert id["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
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

  test "load_dotenv reads ./.env, strips quotes, and lets shell exports win" do
    dir = Path.join(System.tmp_dir!(), "aiur-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "# token\nGITHUB_TOKEN=fromfile\nFOO=\"bar baz\"\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src = "cd #{dir}; source #{@engine}; load_dotenv; echo \"TOK=$GITHUB_TOKEN|FOO=$FOO\""
    {out, 0} = System.cmd("bash", ["-c", src], stderr_to_stdout: true)
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
end
