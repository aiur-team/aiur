defmodule Aiur.RepoBaseTest do
  # async: false — refresh/3 broadcasts on the global "prewarm:phase" topic, so
  # the phase-event test must not race other tests emitting on the same topic.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.RepoBase

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_rb_#{System.unique_integer([:positive])}")
    origin = Path.join(tmp, "origin")
    base = Path.join(tmp, "base")
    File.mkdir_p!(origin)

    git!(["init", "--quiet", "-b", "main", origin])
    git!(["-C", origin, "config", "user.email", "test@example.com"])
    git!(["-C", origin, "config", "user.name", "Test"])
    File.write!(Path.join(origin, "README.md"), "v1\n")
    git!(["-C", origin, "add", "."])
    git!(["-C", origin, "commit", "--quiet", "-m", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, origin: origin, base: base}
  end

  describe "refresh/3" do
    test "clones and builds on first refresh, marking the base built", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build command did not run"
      assert File.exists?(Path.join(base, ".aiur-base-built")), "built marker missing"
      assert head(base) == head(origin)
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

    test "returns an error and skips the marker when base_build fails", %{origin: origin, base: base} do
      log =
        capture_log(fn ->
          assert {:error, {:base_build_failed, status, out}} =
                   RepoBase.refresh(base, origin, "echo failed-output; exit 3")

          assert status == 3
          assert out =~ "failed-output"
        end)

      assert log =~ "prewarm base_build failed"
      assert log =~ "failed-output"
      assert log =~ "status 3"
      refute File.exists?(Path.join(base, ".aiur-base-built"))
    end

    test "trusts mise config files from the base checkout for base_build", %{origin: origin, base: base} do
      File.write!(Path.join(origin, "mise.toml"), "[tools]\n")
      git!(["-C", origin, "add", "mise.toml"])
      git!(["-C", origin, "commit", "--quiet", "-m", "add mise config"])

      assert {:ok, ^base} =
               RepoBase.refresh(
                 base,
                 origin,
                 "printf '%s' \"$MISE_TRUSTED_CONFIG_PATHS\" > trusted_paths"
               )

      trusted_paths =
        base
        |> Path.join("trusted_paths")
        |> File.read!()
        |> String.split(":", trim: true)

      assert Path.join(base, "mise.toml") in trusted_paths
    end

    test "does not overwrite inherited mise trusted config paths", %{origin: origin, base: base} do
      inherited = Path.join(System.tmp_dir!(), "inherited-mise.toml")
      File.write!(Path.join(origin, "mise.toml"), "[tools]\n")
      git!(["-C", origin, "add", "mise.toml"])
      git!(["-C", origin, "commit", "--quiet", "-m", "add mise config"])

      previous = System.get_env("MISE_TRUSTED_CONFIG_PATHS")
      System.put_env("MISE_TRUSTED_CONFIG_PATHS", inherited)

      try do
        assert {:ok, ^base} =
                 RepoBase.refresh(
                   base,
                   origin,
                   "printf '%s' \"$MISE_TRUSTED_CONFIG_PATHS\" > trusted_paths"
                 )

        trusted_paths =
          base
          |> Path.join("trusted_paths")
          |> File.read!()
          |> String.split(":", trim: true)

        assert Path.join(base, "mise.toml") in trusted_paths
        assert inherited in trusted_paths
      after
        if previous do
          System.put_env("MISE_TRUSTED_CONFIG_PATHS", previous)
        else
          System.delete_env("MISE_TRUSTED_CONFIG_PATHS")
        end
      end
    end

    test "returns the base_build exit status", %{origin: origin, base: base} do
      assert {:error, {:base_build_failed, status, _out}} = RepoBase.refresh(base, origin, "exit 3")
      assert status == 3
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
    test "slugs the base directory to <owner>/<name> under the base root" do
      assert RepoBase.base_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-2) ==
               ["foo", "bar"]

      assert RepoBase.base_path("git@github.com:foo/bar.git") |> Path.split() |> Enum.take(-2) ==
               ["foo", "bar"]
    end
  end

  describe "status/0" do
    test "returns a {phase, base_path} tuple" do
      assert {_phase, _base} = RepoBase.status()
    end
  end

  describe "server state machine" do
    setup do
      # An unnamed instance so we can drive its handlers without colliding with
      # the supervised singleton (which always registers __MODULE__).
      {:ok, pid} = GenServer.start_link(RepoBase, [])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
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

      assert %{phase: :ready, base_path: "/base", ready_head: "abc", build: nil} = :sys.get_state(pid)
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
      :sys.replace_state(pid, fn s -> %{s | build: nil, phase: :ready, ready_head: "old"} end)

      send(pid, {:remote_head, "new"})

      # resolve is disabled in test, so the triggered rebuild resolves to idle.
      assert %{phase: :idle, probe: nil} = :sys.get_state(pid)
    end

    test "a remote-head with no advance leaves a ready base untouched", %{server: pid} do
      :sys.replace_state(pid, fn s -> %{s | build: nil, phase: :ready, ready_head: "same"} end)

      send(pid, {:remote_head, "same"})

      assert %{phase: :ready} = :sys.get_state(pid)
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
