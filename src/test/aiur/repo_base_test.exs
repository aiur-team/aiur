defmodule Aiur.RepoBaseTest do
  # async: false — refresh/3 broadcasts on the global "prewarm:phase" topic, so
  # the phase-event test must not race other tests emitting on the same topic.
  use ExUnit.Case, async: false

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
      assert {:error, {:base_build_failed, status, _out}} = RepoBase.refresh(base, origin, "exit 3")
      assert status == 3
      refute File.exists?(Path.join(base, ".aiur-base-built"))
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
