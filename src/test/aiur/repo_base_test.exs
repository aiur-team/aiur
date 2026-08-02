defmodule Aiur.RepoBaseTest do
  # async: false — refresh/3 broadcasts on the global "prewarm:phase" topic, so
  # the phase-event test must not race other tests emitting on the same topic.
  use ExUnit.Case, async: false

  alias Aiur.RepoBase

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_rb_#{System.unique_integer([:positive])}")
    origin = Path.join(tmp, "origin")
    node = Path.join(tmp, "repo/owner/project")
    base = Path.join(node, "latest")
    File.mkdir_p!(origin)

    git!(["init", "--quiet", "-b", "main", origin])
    git!(["-C", origin, "config", "user.email", "test@example.com"])
    git!(["-C", origin, "config", "user.name", "Test"])
    File.write!(Path.join(origin, "README.md"), "v1\n")
    git!(["-C", origin, "add", "."])
    git!(["-C", origin, "commit", "--quiet", "-m", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, origin: origin, node: node, base: base}
  end

  describe "refresh/3" do
    test "clones and builds on first refresh, writing a SHA-keyed base record beside latest", %{origin: origin, node: node, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build command did not run"
      assert {:ok, record_body} = File.read(Path.join(node, "base-record.json"))
      assert {:ok, record} = Jason.decode(record_body)
      assert record["clone_head"] == head(origin)
      assert is_binary(record["prewarm_script_hash"])
      assert is_binary(record["built_at"])
      refute File.exists?(Path.join(base, ".aiur-base-built"))
      assert head(base) == head(origin)
    end

    test "rebuilds when the prewarm script changes without a new commit", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch first_build")
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch second_build")

      assert File.exists?(Path.join(base, "second_build"))
    end

    test "migrates an existing clone down to latest and leaves sidecars at the repo node", %{origin: origin, node: node, base: base} do
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      File.write!(Path.join(node, ".aiur-base-built"), "")
      File.mkdir_p!(Path.join(node, ".aiur-hex"))
      File.write!(Path.join(node, ".aiur-hex/cache"), "warm")
      File.write!(Path.join(node, "latest"), "legacy tracked path")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch rebuilt_after_migration")

      assert File.dir?(Path.join(base, ".git"))
      refute File.dir?(Path.join(node, ".git"))
      assert File.read!(Path.join(base, "latest")) == "legacy tracked path"
      assert File.exists?(Path.join(node, ".aiur-hex/cache"))
      refute File.exists?(Path.join(base, ".aiur-hex/cache"))
      refute File.exists?(Path.join(base, ".aiur-base-built"))
      assert File.exists?(Path.join(base, "rebuilt_after_migration"))
    end

    test "recovers a clone parked by an interrupted migration", %{origin: origin, node: node, base: base} do
      parked = node <> ".migrating-interrupted"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(node)
      File.mkdir_p!(Path.join(node, ".aiur-mix"))

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch rebuilt_after_recovery")

      assert File.dir?(Path.join(base, ".git"))
      assert File.exists?(Path.join(base, "rebuilt_after_recovery"))
      refute File.exists?(parked)
    end

    test "is idempotent when main has not advanced", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      refute File.exists?(Path.join(base, "built_ran")),
             "base_build re-ran even though main did not advance"
    end

    test "rebuilds when main advances", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      File.write!(Path.join(origin, "README.md"), "v2\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "advance"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build did not re-run after advance"
      assert head(base) == head(origin)
    end

    test "tracks configured v2 and ignores a main-only advance", %{origin: origin, base: base, tmp: tmp} do
      git!(["-C", origin, "checkout", "-b", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 initial\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 initial"])
      v2_initial = head(origin)

      config = Path.join(tmp, "v2.aiurconfig")
      previous_config = Application.get_env(:aiur, :workflow_file_path)
      File.write!(config, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(config)

      on_exit(fn ->
        case previous_config do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      File.rm!(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "main"])
      File.write!(Path.join(origin, "README.md"), "main only\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "main only"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      refute File.exists?(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 advanced\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 advanced"])
      v2_advanced = head(origin)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_advanced
      assert File.exists?(Path.join(base, "built_ran"))
    end

    test "returns an error and skips the marker when base_build fails", %{origin: origin, base: base} do
      assert {:error, {:base_build_failed, status, _out}} = RepoBase.refresh(base, origin, "exit 3")
      assert status == 3
      refute File.exists?(Path.join(Path.dirname(base), "base-record.json"))
    end

    test "runs base_build with the base mise.toml trusted", %{origin: origin, base: base} do
      # base_build records the trust path it actually ran with; proves base_env/1
      # reached the build shell (regression for the untrusted-base prewarm hang).
      assert {:ok, ^base} =
               RepoBase.refresh(base, origin, ~s(printf '%s' "$MISE_TRUSTED_CONFIG_PATHS" > trust_path))

      assert File.read!(Path.join(base, "trust_path")) =~ base
    end

    test "prewarm build succeeds with release launcher environment", %{origin: origin, base: base} do
      release_env = [
        {"ROOTDIR", "/outer/release"},
        {"BINDIR", "/outer/release/erts/bin"},
        {"EMU", "beam"},
        {"PROGNAME", "erl"}
      ]

      previous_env =
        Map.new(release_env, fn {name, _value} ->
          {name, System.get_env(name)}
        end)

      Enum.each(release_env, fn {name, value} -> System.put_env(name, value) end)

      on_exit(fn ->
        Enum.each(previous_env, fn {name, value} ->
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end)
      end)

      assert {:ok, ^base} =
               RepoBase.refresh(
                 base,
                 origin,
                 ~s(test -z "$ROOTDIR" -a -z "$BINDIR" -a -z "$EMU" -a -z "$PROGNAME" && touch release_env_scrubbed)
               )

      assert File.exists?(Path.join(base, "release_env_scrubbed"))
    end

    test "keeps package-manager caches beside latest rather than in the clone", %{origin: origin, node: node, base: base} do
      command = ~s(mkdir -p "$HEX_HOME" "$MIX_HOME" "$npm_config_cache"; touch "$HEX_HOME/hex" "$MIX_HOME/mix" "$npm_config_cache/npm")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, command)

      for cache <- [".aiur-hex/hex", ".aiur-mix/mix", ".aiur-npm-cache/npm"] do
        assert File.exists?(Path.join(node, cache))
        refute File.exists?(Path.join(base, cache))
      end
    end

    test "logs base_build failures at error with the captured output", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:base_build_failed, 3, _}} =
                   RepoBase.refresh(base, origin, "echo boom 1>&2; exit 3")
        end)

      assert log =~ "prewarm base unavailable"
      assert log =~ "boom"
    end

    test "does not log a prewarm error on a successful base_build", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
        end)

      refute log =~ "prewarm base unavailable"
    end

    test "never persists the auth header into the cloned repo's git config", %{origin: origin, base: base} do
      # The token rides in env-config (GIT_CONFIG_*), so it must never be written
      # into the cloned repo's own config the way a token-in-URL or `-c` would.
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      config = File.read!(Path.join(base, ".git/config"))
      refute config =~ "extraheader"
      refute config =~ "Authorization"
      refute config =~ "x-access-token"
    end

    test "emits ordered phase events", %{origin: origin, base: base} do
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      assert_receive {:prewarm_phase, :cloning}, 5_000
      assert_receive {:prewarm_phase, :fetching}, 5_000
      assert_receive {:prewarm_phase, :building}, 5_000
      assert_receive {:prewarm_phase, :ready}, 5_000
    end
  end

  describe "base_path/1" do
    test "puts the base clone at <owner>/<name>/latest under the base root" do
      assert RepoBase.base_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]

      assert RepoBase.base_path("git@github.com:foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]
    end

    test "keeps the build store beside latest in the repository state node" do
      assert RepoBase.builds_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "builds"]
    end
  end

  describe "base_branch/0" do
    # Pins the workflow config per test (same pattern as the "server state
    # machine" setup below) so resolution never depends on ambient config.
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb_bb_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      prev_path = Application.get_env(:aiur, :workflow_file_path)

      on_exit(fn ->
        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        File.rm_rf!(tmp)
      end)

      {:ok, cfg: cfg}
    end

    test "defaults to main when tracker.base_branch is unset", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "main"
    end

    test "returns the configured tracker.base_branch", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "v2"
    end

    test "falls back to main when tracker.base_branch is empty", %{cfg: cfg} do
      File.write!(cfg, ~s(tracker:\n  kind: memory\n  base_branch: ""\n))
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "main"
    end
  end

  describe "status/0" do
    test "returns a {phase, base_path} tuple" do
      assert {_phase, _base} = RepoBase.status()
    end
  end

  describe "server state machine" do
    setup do
      # Pin a prewarm-disabled config and force the shared WorkflowStore cache to
      # reload it, so `resolve/0` is deterministically `:disabled` and the instance
      # never schedules a poll. Otherwise a sibling test that left a prewarm-enabled
      # config cached makes the auto-poll start a real build mid-test (flaky).
      tmp = Path.join(System.tmp_dir!(), "rb_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      File.write!(cfg, "tracker:\n  kind: memory\n")
      prev_path = Application.get_env(:aiur, :workflow_file_path)
      Aiur.Workflow.set_workflow_file_path(cfg)

      # An unnamed instance so we can drive its handlers without colliding with
      # the supervised singleton (which always registers __MODULE__).
      {:ok, pid} = GenServer.start_link(RepoBase, [])

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(pid)

        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        File.rm_rf!(tmp)
      end)

      {:ok, server: pid}
    end

    test "starts idle", %{server: pid} do
      assert %{phase: :idle, build: nil, probe: nil} = :sys.get_state(pid)
    end

    test "refresh_async is a no-op when pre-warm is disabled", %{server: pid} do
      GenServer.cast(pid, :refresh_async)
      assert %{phase: :idle} = :sys.get_state(pid)
    end

    test "build_done success marks ready and records the head", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: "abc"}, phase: :building}
      end)

      send(pid, {:build_done, pid, "abc", {:ok, "/base"}})

      assert %{phase: :ready, base_path: "/base", ready_head: "abc", freshness: :unknown, build: nil} =
               :sys.get_state(pid)
    end

    test "build_done error sets the error phase", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: nil}, phase: :building}
      end)

      send(pid, {:build_done, pid, nil, {:error, :boom}})

      assert %{phase: {:error, :boom}, build: nil} = :sys.get_state(pid)
    end

    test "build_head records the locked head on the in-flight build", %{server: pid} do
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: pid, ref: make_ref(), head: nil}} end)

      send(pid, {:build_head, pid, "deadbeef"})

      assert %{build: %{head: "deadbeef"}} = :sys.get_state(pid)
    end

    test "a crashed build process surfaces an error phase", %{server: pid} do
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: self(), ref: ref, head: nil}, phase: :building} end)

      send(pid, {:DOWN, ref, :process, self(), :killed})

      assert %{phase: {:error, {:build_crashed, :killed}}, build: nil} = :sys.get_state(pid)
    end

    test "a remote-head advance past a ready base triggers a rebuild", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "old", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "new"}})

      # resolve is disabled in test, so the triggered rebuild resolves to idle.
      assert %{phase: :idle, probe: nil} = :sys.get_state(pid)
    end

    test "a remote-head with no advance leaves a ready base untouched", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "same", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready} = :sys.get_state(pid)
    end

    test "a matching dispatch freshness check marks the ready base fresh", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready, freshness: :fresh} = :sys.get_state(pid)
    end

    test "a failed freshness check never certifies the warm base", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:error, :timeout}})

      assert %{phase: {:error, {:repo_base_remote_probe_failed, :timeout}}, freshness: :unknown} =
               :sys.get_state(pid)
    end
  end

  defp probe(pid), do: %{pid: pid, ref: make_ref(), timer: nil}

  describe "git_auth_env/1" do
    test "injects the token as a per-host Authorization header via env config" do
      env = RepoBase.git_auth_env("ghp_secrettoken")
      assert {"GIT_CONFIG_COUNT", "1"} in env
      assert {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) == "x-access-token:ghp_secrettoken"
    end

    test "carries the secret only in the env (base64-encoded), never in plaintext" do
      # The token rides in `env:` to System.cmd, never on argv, and even there it
      # only appears base64-encoded inside the Authorization header — so a raw
      # token string never lands in argv/`ps` or the env list verbatim.
      env = RepoBase.git_auth_env("ghp_secrettoken")
      refute inspect(env) =~ "ghp_secrettoken"

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) =~ "ghp_secrettoken"
    end

    test "with no token, disables the terminal prompt and injects no credential" do
      for token <- [nil, ""] do
        env = RepoBase.git_auth_env(token)
        assert env == [{"GIT_TERMINAL_PROMPT", "0"}]
        refute Enum.any?(env, fn {k, _v} -> String.starts_with?(k, "GIT_CONFIG") end)
      end
    end
  end

  defp git!(args) do
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp head(repo) do
    {out, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(out)
  end
end
