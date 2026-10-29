defmodule ScriptsAiurdevCheckoutTest do
  # async: false — see ScriptsAiurdevTest (File.cd! is process-global, #589).
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

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
          Aiur.TestSupport.tmp_root!("9001")
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

    test "github-cost from another checkout reads the daemon instead of being refused" do
      # `github-cost` reads the meter the daemon already keeps and builds
      # nothing, so it belongs on the read-only side of the divergence guard.
      # Listing it in one command table and not the other would refuse a
      # read-only report from any checkout but the shim's own.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["github-cost", "--budget", "graphql"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: github-cost --budget graphql"
    end

    test "github-usage from another checkout reads the daemon instead of being refused" do
      # `github-usage` reads the broker the daemon already keeps and builds
      # nothing, so it belongs on the read-only side of the divergence guard
      # alongside `github-cost`.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["github-usage", "--json"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: github-usage --json"
    end

    test "history export from another checkout reads the daemon instead of being refused" do
      # `history export` reads the daemon's local History store and builds
      # nothing; left off the read-only list, the fallthrough would treat it
      # as a run and refuse it from any checkout but the shim's own.
      {checkout_a, shim_a} = fake_checkout()
      {checkout_b, _shim_b} = fake_checkout()
      link = global_shim(shim_a)

      seed_ready_release(checkout_a)

      {out, 0} =
        run_shim(
          ["history", "export", "--unsorted"],
          [{"AIUR_REPO_ROOT", nil}, {"TMUX", nil}],
          script: link,
          cd: checkout_b
        )

      assert out =~ "ENGINE_ARGS: history export --unsorted"
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
          cd: Path.join(isolated_tmp_root(), "no-checkout")
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
      partial = Path.join(isolated_tmp_root(), "aiurdev-partial")
      File.mkdir_p!(Path.join([partial, "packaging", "npm", "aiur-cli", "libexec"]))
      File.mkdir_p!(Path.join(partial, "scripts"))
      File.write!(Path.join([partial, "scripts", "aiurdev"]), "")
      File.write!(Path.join([partial, "packaging", "npm", "aiur-cli", "libexec", "aiur-engine.sh"]), "")
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
end
