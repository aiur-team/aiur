defmodule ScriptsAiurdevTest do
  # async: false — the shim tests File.cd! the BEAM; cwd is process-global (#589).
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

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

  test "refuses aiur upgrade (a dev checkout cannot install a published release)" do
    root = fake_repo()

    {out, code} =
      run_shim(["upgrade"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"TMUX", nil}
      ])

    assert code == 64
    assert out =~ "cannot run under aiurdev"
    assert out =~ "a development checkout"
    assert out =~ "Install aiur from npm"
    refute out =~ "rebuilding"
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

  test "pre-pr stays on the control path without a pinned opencode install" do
    root = fake_repo()
    cwd = Aiur.TestSupport.tmp_root!("aiurdev-pre-pr-control")
    File.mkdir_p!(cwd)
    File.touch!(Path.join(cwd, "pre-pr"))

    for {file, function, code} <- [
          {script(), "targets_release_deliberately", 1},
          {script(), "pure_control_command", 0},
          {Path.expand("../../scripts/lib/aiurdev-toolchain.sh", __DIR__), "requires_pinned_opencode", 1}
        ] do
      source = File.read!(file)
      [definition] = Regex.run(~r/^#{function}\(\) \{.*?^\}/ms, source)
      assert {"", ^code} = System.cmd("bash", ["-c", "cd #{cwd} && #{definition}\n#{function} pre-pr"])
    end

    {out, 0} =
      run_shim(["pre-pr"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_SKIP_BUILD", "1"},
        {"AIUR_MISE_BIN", Path.join(root, "missing-mise")},
        {"TMUX", nil}
      ])

    assert out =~ "ENGINE_ARGS: pre-pr"
    refute out =~ "rebuilding"
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

    refute File.exists?(Path.join([root, "src", "_build", ".aiurdev-build.lock"])),
           "concurrent rebuilds must release the lock once all runners have exited"
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
          {["epic", "list"], "ENGINE_ARGS: epic list"},
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
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(lock) end)

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
end
