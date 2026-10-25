defmodule Aiur.GitHub.Config.KeyringTest do
  import Aiur.GitHub.Config.TestFixtures

  # async: false — these tests mutate the GITHUB_TOKEN env var and the shared
  # :persistent_term cache, so they must not run concurrently.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config

  @cache_key {Aiur.GitHub.Access.Token, :resolved_token}
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"
  @source_cache_key {Aiur.GitHub.Access.Token, :resolved_token_source}

  setup do
    original = System.get_env("GITHUB_TOKEN")
    original_keyring_timeout = System.get_env(@keyring_timeout_env)

    on_exit(fn ->
      :persistent_term.erase(@cache_key)
      :persistent_term.erase(@source_cache_key)

      case original do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end

      case original_keyring_timeout do
        nil -> System.delete_env(@keyring_timeout_env)
        value -> System.put_env(@keyring_timeout_env, value)
      end
    end)

    :ok
  end

  describe "keyring_token/1 — the gh auth token shell-out" do
    test "returns the stored token when gh answers promptly" do
      with_fake_gh_on_path(
        """
        if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
          printf 'ghs_keyring_only_token\\n'
          exit 0
        fi
        """,
        fn ->
          assert Config.keyring_token() == "ghs_keyring_only_token"
        end
      )
    end

    test "returns nil within the timeout when gh never returns, instead of hanging" do
      with_fake_gh_on_path(
        """
        if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
          while true; do sleep 1; done
        fi
        """,
        fn ->
          started = System.monotonic_time(:millisecond)
          assert Config.keyring_token(timeout_ms: 200) == nil
          elapsed = System.monotonic_time(:millisecond) - started

          # Completed promptly and treated the stall as "no keyring credential".
          assert elapsed < 5_000
        end,
        assert_reaped: true
      )
    end

    test "logs before the shell-out so a hang is attributable" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              printf 'ghs_keyring_only_token\\n'
              exit 0
            fi
            """,
            fn ->
              assert Config.keyring_token(timeout_ms: 1_000) == "ghs_keyring_only_token"
            end
          )
        end)

      assert log =~ "github_keyring_lookup"
      assert log =~ "state=starting"
      assert log =~ "timeout_ms=1000"
    end

    test "logs a warning and returns nil when the shell-out times out" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              while true; do sleep 1; done
            fi
            """,
            fn ->
              assert Config.keyring_token(timeout_ms: 200) == nil
            end,
            assert_reaped: true
          )
        end)

      assert log =~ "github_keyring_lookup"
      assert log =~ "state=timed_out"
      assert log =~ "gh auth login"
    end

    test "returns nil when no gh resolves on PATH (the missing-binary degradation)" do
      # A box with no gh at all: HostCommand.find_executable/1 resolves nothing
      # and the runner returns {"", 127}, which keyring_token/1 treats exactly
      # like a failed lookup — nil — so the boot gate can raise its normal
      # missing-credential message. This is the {"", 127} degradation path, not
      # an :enoent raise: HostCommand guards its System.cmd call, so a gh-less
      # PATH never reaches the raising path. The raising path is covered
      # separately by the injected-runner test below.
      with_empty_path(fn ->
        assert Config.keyring_token(timeout_ms: 1_000) == nil
      end)
    end

    test "a runner that raises degrades to nil instead of killing the caller" do
      # Review blocker: Task.async links the shell-out task to the caller, so an
      # uncaught exception inside the task exits it abnormally and the link
      # kills the caller before Task.yield ever returns. The rescue lives inside
      # the task and turns any runner failure into "no keyring credential".
      # The :run_fun seam drives a runner that actually raises, making that
      # rescue load-bearing — without the seam, the rescue was untestable
      # because HostCommand.run degrades a missing binary to {"", 127} before
      # System.cmd can raise :enoent.
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> raise "boom" end) == nil
    end

    test "a runner that throws or exits degrades to nil instead of killing the caller" do
      # The in-task guard is `catch _, _ -> nil` as well as `rescue _ -> nil`:
      # rescue alone only covers raises, so a `throw` or `exit` from run_fun
      # would exit the linked task abnormally and kill the caller across the
      # link by the same path as an uncaught raise. Both must degrade to "no
      # keyring credential" instead.
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> throw(:boom) end) == nil
      assert Config.keyring_token(timeout_ms: 1_000, run_fun: fn -> exit(:boom) end) == nil
    end

    test "a stalled gh and the process it spawned are killed together on timeout" do
      # Review blocker: the timeout kill must target the whole process GROUP,
      # not just the direct child. On a host where the guard wrapper
      # (~/.aiur/bin/gh) is the port program, the direct pid is the wrapper
      # shell and the real `gh` runs as its child — a single-pid kill would
      # orphan it, still holding the locked keyring. The BEAM's port spawn
      # makes the direct child a group leader (os_pid == pgid), so a
      # negative-pid kill reaches the wrapper AND everything it spawned. This
      # test drives the real shell-out against a never-returning fake gh that
      # spawns a grandchild and records both pids, then asserts neither is live
      # after the lookup returns — the grandchild dying is what makes the group
      # kill distinguishable from a direct-pid kill.
      root = Aiur.TestSupport.tmp_root!("aiur-config-keyring-orphan")
      File.mkdir_p!(root)
      pidfile = Path.join(root, "gh.pid")
      childfile = Path.join(root, "gh.child.pid")

      try do
        with_fake_gh_on_path(
          """
          if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
            echo $$ > #{pidfile}
            sleep 300 &
            echo $! > #{childfile}
            while true; do sleep 1; done
          fi
          """,
          fn ->
            assert Config.keyring_token(timeout_ms: 200) == nil
            assert File.exists?(pidfile), "the fake gh never started"
            assert File.exists?(childfile), "the fake gh never spawned its child"

            pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()
            child = childfile |> File.read!() |> String.trim() |> String.to_integer()

            # Allow the kill and reap to land, then assert neither the fake gh
            # nor its spawned child is a live process (a reaped pid or a zombie
            # both count dead).
            Process.sleep(200)
            refute live_process?(pid), "gh pid #{pid} survived the timeout"
            refute live_process?(child), "gh child pid #{child} survived the timeout"
          end
        )
      after
        File.rm_rf!(root)
      end
    end

    test "the direct pid is still signalled when the descendant walk yields garbage" do
      # Review blocker: `kill_os_process/1` computed `[pid | descendant_os_pids(pid)]`
      # BEFORE sending any signal, and the walk parsed pgrep output — captured
      # with `stderr_to_stdout: true` — with `String.to_integer/1`. One
      # non-numeric byte on that stream raised, the function-level
      # `rescue _ -> :ok` swallowed it, and NO signal was sent at all: the
      # silent failure that let 76 stalled `gh` processes accumulate.
      #
      # The pgrep stream here carries a warning line and a blank line as well as
      # a real child pid. The direct pid must be TERMed and KILLed regardless,
      # and the one parseable child pid must still be killed.
      test_pid = self()

      signal_fun = fn signal, target ->
        send(test_pid, {:signal, signal, target})
        :ok
      end

      pgrep_fun = fn
        4242 -> {"pgrep: warning from stderr\nnot-a-pid\n\n4343\n", 0}
        _other -> {"", 1}
      end

      assert Config.kill_os_process(4242, signal_fun: signal_fun, pgrep_fun: pgrep_fun) == :ok

      signals = drain_signals()

      assert {"TERM", 4242} in signals, "the direct pid was never TERMed: #{inspect(signals)}"
      assert {"KILL", 4242} in signals, "the direct pid was never KILLed: #{inspect(signals)}"
      assert {"KILL", 4343} in signals, "the parseable child pid was dropped: #{inspect(signals)}"
    end

    test "no signal is ever aimed at a process group" do
      # #2560. On a GitHub-hosted runner the whole job shares one process
      # group: Runner.Listener, Runner.Worker and the step shell all sat in
      # pgid 2034 on the runner that failed. A `kill -<sig> -<pgid>` from
      # inside the suite therefore SIGTERMs the Actions runner itself. The job
      # died mid-step with exit 143, "the runner has received a shutdown
      # signal", and no test output at all; an instrumented run put 8 ms
      # between this function's group signal and the runner's death.
      #
      # A process group is not this code's to signal. Every target must be a
      # pid the descendant walk actually found.
      test_pid = self()

      signal_fun = fn signal, target ->
        send(test_pid, {:signal, signal, target})
        :ok
      end

      pgrep_fun = fn
        4242 -> {"4343\n", 0}
        4343 -> {"4344\n", 0}
        _other -> {"", 1}
      end

      assert Config.kill_os_process(4242, signal_fun: signal_fun, pgrep_fun: pgrep_fun) == :ok

      signals = drain_signals()

      assert {"TERM", 4242} in signals, "the direct pid was never TERMed: #{inspect(signals)}"
      assert {"KILL", 4242} in signals, "the direct pid was never KILLed: #{inspect(signals)}"

      assert {"TERM", 4343} in signals, "the descendant was never TERMed: #{inspect(signals)}"
      assert {"KILL", 4343} in signals, "the descendant was never KILLed: #{inspect(signals)}"
      assert {"KILL", 4344} in signals, "the grandchild was never KILLed: #{inspect(signals)}"

      refute Enum.any?(signals, fn {_signal, target} -> target < 0 end),
             "a process group was signalled: #{inspect(signals)}"
    end

    test "a stalled gh that is the DIRECT port child is killed (the CI topology)" do
      # Review blocker: local runs killed the fake `gh` while CI did not, and
      # the difference is topology. `keyring_token/1` resolves through
      # `HostCommand.find_executable/1`, which prefers `~/.aiur/bin/gh`: on a
      # dev box the port child is that wrapper and the fake `gh` is a
      # GRANDchild, so the descendant walk saved it even when the direct-pid
      # kill was lost. On CI no wrapper is installed, the fake IS the direct
      # child, and nothing else covers it. The `:wrapper_dir` seam points at an
      # empty directory so the wrapper never resolves and this test drives the
      # CI topology deliberately on any host.
      root = Aiur.TestSupport.tmp_root!("aiur-config-keyring-no-wrapper")
      File.mkdir_p!(root)
      pidfile = Path.join(root, "gh.pid")
      childfile = Path.join(root, "gh.child.pid")

      try do
        with_fake_gh_on_path(
          """
          if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
            echo $$ > #{pidfile}
            sleep 300 &
            echo $! > #{childfile}
            while true; do sleep 1; done
          fi
          """,
          fn ->
            assert Config.keyring_token(timeout_ms: 200, wrapper_dir: root) == nil
            assert File.exists?(pidfile), "the fake gh never started"
            assert File.exists?(childfile), "the fake gh never spawned its child"

            pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()
            child = childfile |> File.read!() |> String.trim() |> String.to_integer()

            Process.sleep(200)
            refute live_process?(pid), "direct-child gh pid #{pid} survived the timeout"

            # The descendant walk must run BEFORE the TERM: a TERM to the
            # direct child reparents this one to init, after which
            # `pgrep -P <pid>` cannot find it.
            refute live_process?(child), "child pid #{child} of the direct gh was orphaned"
          end
        )
      after
        File.rm_rf!(root)
      end
    end

    test "the shipped default timeout is bounded so a boot stall cannot ship unnoticed" do
      # Pins @keyring_command_timeout_ms in the safe direction: every other test
      # injects its own timeout_ms or pins the env override, so a mutation to a
      # ten-minute stall would otherwise leave the whole suite green while boot
      # hangs. Boot must fail fast on a locked keyring.
      System.delete_env(@keyring_timeout_env)

      timeout = Config.keyring_command_timeout_ms()
      assert is_integer(timeout)
      assert timeout >= 1
      assert timeout <= 10_000
    end

    test "AIUR_GH_KEYRING_TIMEOUT_MS overrides the default timeout" do
      System.put_env(@keyring_timeout_env, "7000")

      assert Config.keyring_timeout_ms() == 7_000
      assert Config.keyring_timeout_ms(timeout_ms: 1_000) == 1_000
    end

    test "an invalid AIUR_GH_KEYRING_TIMEOUT_MS falls back to the compiled default" do
      for bad <- ["banana", "0", "-5", ""] do
        System.put_env(@keyring_timeout_env, bad)
        assert Config.keyring_timeout_ms() == Config.keyring_command_timeout_ms()
      end
    end

    test "the env override is applied to the real shell-out" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          with_fake_gh_on_path(
            """
            if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
              printf 'ghs_env_override\\n'
              exit 0
            fi
            """,
            fn ->
              System.put_env(@keyring_timeout_env, "900")
              assert Config.keyring_token() == "ghs_env_override"
            end
          )
        end)

      assert log =~ "timeout_ms=900"
    end
  end
end
