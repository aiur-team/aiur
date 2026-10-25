defmodule ScriptsAiurdevReleaseTest do
  # async: false — see ScriptsAiurdevTest (File.cd! is process-global, #589).
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

  test "remote targets bypass local release work and reach engine validation" do
    root = fake_repo()
    engine = Path.join([root, "packaging", "npm", "aiur-cli", "libexec", "aiur-engine.sh"])

    File.write!(
      engine,
      "#!/usr/bin/env bash\n" <>
        ~s|printf 'ENGINE_ARGS: %s\nREMOTE_INSTANCE: %s\n' "$*" "${AIUR_REMOTE_INSTANCE:-}"| <>
        "\nif [ \"${1:-}\" = --instance ]; then shift 2; fi\n" <>
        "if [ \"${1:-}\" = build ]; then exit 64; fi\n"
    )

    File.chmod!(engine, 0o755)
    missing_mise = Path.join(root, "missing-mise")

    for {command, expected_status} <- [{"status", 0}, {"build", 64}] do
      {out, ^expected_status} =
        run_shim(["--instance", "nuc", command], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", missing_mise},
          {"TMUX", "inside-tmux"}
        ])

      assert out =~ "ENGINE_ARGS: --instance nuc #{command}"
      assert out =~ "REMOTE_INSTANCE: "
      refute out =~ "REMOTE_INSTANCE: nuc"
      refute out =~ "mise not found"
      refute out =~ "force-rebuild"
    end
  end

  describe "release provenance" do
    test "a changed dependency lock fetches dependencies before compilation" do
      root = fake_repo()
      mise = fake_mise()
      order_log = Path.join(root, "build-order.log")

      seed_ready_release(root)
      File.mkdir_p!(Path.join(root, "src/deps/example"))
      File.write!(Path.join(root, "src/deps/example/version"), "old")
      File.write!(Path.join(root, "src/mix.lock"), "%{\n  \"example\": {:hex, :example, \"2.0.0\"}\n}\n")

      {_out, 0} =
        run_shim(["__ensure-build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_ORDER_LOG", order_log},
          {"TMUX", nil}
        ])

      assert File.read!(order_log) == "deps.get\ncompile\ncompile\n"

      assert String.trim(File.read!(Path.join(root, "src/_build/dev/aiurdev-deps-lock-sha"))) ==
               Base.encode16(:crypto.hash(:sha256, File.read!(Path.join(root, "src/mix.lock"))), case: :lower)
    end

    test "a failed staged build leaves the existing release untouched" do
      root = fake_repo()
      mise = fake_mise()
      seed_ready_release(root)
      existing_bin = Path.join(root, "src/_build/dev/rel/aiur/bin/aiur")
      existing_launcher = Path.join(root, "src/bin/aiur")
      File.write!(existing_bin, "running release sentinel")
      File.write!(existing_launcher, "running launcher sentinel")
      assert File.exists?(existing_bin)

      {out, 9} =
        run_shim(["build"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
          {"TMUX", nil}
        ])

      assert out =~ "keeping the previous release"
      assert File.read!(existing_bin) == "running release sentinel"
      assert File.read!(existing_launcher) == "running launcher sentinel"
      assert File.exists?(release_stamp_path(root))
    end

    test "a failed clean build preserves the existing release" do
      root = fake_repo()
      mise = fake_mise()
      seed_ready_release(root)
      existing_bin = Path.join(root, "src/_build/dev/rel/aiur/bin/aiur")
      File.write!(existing_bin, "running release sentinel")

      {out, 9} =
        run_shim(["build", "--deps"], [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_MISE_BIN", mise},
          {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
          {"TMUX", nil}
        ])

      assert out =~ "keeping the previous release"
      assert File.read!(existing_bin) == "running release sentinel"
    end

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
      launcher = File.read!(Path.join(root, "src/bin/aiur"))

      assert stamp =~ "repo_root=#{root}"
      # Outside a git work tree there is no commit to record; the field is still
      # present so a reader never has to guess whether stamping ran.
      assert stamp =~ "source_sha=unknown"
      assert launcher =~ "release_root=\"#{root}/src/_build/dev/rel/aiur\""
      refute launcher =~ ".aiur-staging"
      assert stamp =~ ~r/built_at=\d{4}-\d{2}-\d{2}T/
    end

    test "a repo root nested inside another repository is not stamped with that repo's commit" do
      # `git -C` walks up to the nearest enclosing repository. Stamping the outer
      # repo's HEAD would claim provenance for a tree nobody built — and would
      # then compare that borrowed SHA against itself on every later launch.
      outer = Aiur.TestSupport.tmp_root!("aiurdev-outer")
      File.mkdir_p!(outer)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(outer) end)
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

  test "rebuild helper failure releases the build lock so subsequent runs can proceed" do
    root = fake_repo()
    # Simulate a missing or non-executable mise so require_mise will exit 64
    lock_dir = Path.join([root, "src", "_build", ".aiurdev-build.lock"])
    missing_mise = Path.join(root, "missing-mise")

    # First run: require_mise will fail during ensure_elixir_deps and the exit trap
    # should release the lock even though require_mise called exit 64
    {out, 64} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", missing_mise},
        {"TMUX", nil}
      ])

    assert out =~ "mise not found"

    refute File.exists?(lock_dir),
           "lock should be released even when require_mise calls exit 64"

    # Second run: should be able to acquire and use the lock without hanging
    # (which would fail if the lock from the first run was left behind)
    {out, 64} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", missing_mise},
        {"TMUX", nil}
      ])

    assert out =~ "mise not found"

    refute File.exists?(lock_dir),
           "lock should still be released after the second run"
  end

  test "a successful locked rebuild releases the lock before exec'ing the engine" do
    root = fake_repo()
    mise = fake_mise()
    lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])

    # The fake engine fails if the build lock is still present when it is
    # exec'd, so this distinguishes "released before exec" (correct) from
    # "released by a trap that could never fire across exec" (the regression
    # the review flagged).
    {out, 0} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_ENGINE_CHECK_NO_LOCK", lock},
        {"TMUX", nil}
      ])

    assert out =~ "rebuilding"
    assert out =~ "ENGINE_ARGS: --bg"
    refute out =~ "FAIL: build lock still present at engine exec"
    refute File.exists?(lock)
  end

  test "a later invocation is not blocked by a successful locked rebuild" do
    root = fake_repo()
    mise = fake_mise()
    lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])

    {out, 0} =
      run_shim(["--bg"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil}
      ])

    assert out =~ "rebuilding"
    refute File.exists?(lock)

    # Release is ready now; the second invocation must proceed without waiting
    # on (or stealing) the lock the first run already released.
    {out2, 0} =
      run_shim(["status"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"TMUX", nil}
      ])

    assert out2 =~ "ENGINE_ARGS: status"
    refute out2 =~ "waiting for aiurdev rebuild lock"
  end

  test "aiurdev build releases the lock when the rebuild itself fails" do
    root = fake_repo()
    mise = fake_mise()
    lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])

    {out, 9} =
      run_shim(["build"], [
        {"AIUR_REPO_ROOT", root},
        {"AIUR_MISE_BIN", mise},
        {"AIUR_FAKE_MISE_FAIL_RELEASE", "1"},
        {"TMUX", nil}
      ])

    assert out =~ "aiur release rebuild failed"
    refute File.exists?(lock), "aiurdev build must release the lock after a failed rebuild"
  end

  test "SIGINT/SIGTERM during a locked rebuild releases the build lock" do
    for signal <- ["INT", "TERM"] do
      root = fake_repo()
      mise = fake_mise()
      lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])
      {pid_file, wrapper} = spawn_shim_with_pid(root, ["--bg"])

      task =
        Task.async(fn ->
          System.cmd("bash", [wrapper],
            env: [
              {"AIUR_REPO_ROOT", root},
              {"AIUR_MISE_BIN", mise},
              {"AIUR_FAKE_MISE_RELEASE_SLEEP", "1.0"},
              {"AIUR_AGENT_WORKSPACE", nil},
              {"TMUX", nil}
            ],
            stderr_to_stdout: true
          )
        end)

      wait_until(fn -> File.exists?(Path.join(lock, "owner")) end, 10_000)

      pid = pid_file |> File.read!() |> String.trim()
      {_kill_out, _kill_code} = System.cmd("kill", ["-#{signal}", pid])

      {_out, _code} = Task.await(task, 20_000)

      refute File.exists?(lock), "SIG#{signal} during a locked rebuild should release the lock"
    end
  end

  test "a stale-reclaim takeover is not deleted by the previous owner's cleanup" do
    root = fake_repo()
    mise = fake_mise()
    lock = Path.join([root, "src", "_build", ".aiurdev-build.lock"])
    {pid_file, wrapper} = spawn_shim_with_pid(root, ["--bg"])
    # A live process that is NOT the shim: the BEAM running this test.
    foreign_owner = "#{System.pid()}"

    task =
      Task.async(fn ->
        System.cmd("bash", [wrapper],
          env: [
            {"AIUR_REPO_ROOT", root},
            {"AIUR_MISE_BIN", mise},
            {"AIUR_FAKE_MISE_RELEASE_SLEEP", "1.0"},
            {"AIUR_AGENT_WORKSPACE", nil},
            {"TMUX", nil}
          ],
          stderr_to_stdout: true
        )
      end)

    wait_until(fn -> File.exists?(Path.join(lock, "owner")) end, 10_000)

    # A second invocation reclaimed the lock as stale and took it over, so the
    # owner file now names a different live process than the original holder.
    File.write!(Path.join(lock, "owner"), foreign_owner)

    # Signal the original holder so its crash-net cleanup runs against the
    # takeover lock: it must NOT delete a lock it no longer owns.
    pid = pid_file |> File.read!() |> String.trim()
    {_kill_out, _kill_code} = System.cmd("kill", ["-TERM", pid])
    {_out, _code} = Task.await(task, 20_000)

    assert File.exists?(lock), "the takeover lock must survive the old owner's cleanup"
    assert File.read!(Path.join(lock, "owner")) == foreign_owner
  end

  # Spawns aiurdev under a wrapper that records its PID before exec'ing, so a
end
