defmodule Aiur.RepoBaseTest do
  use ExUnit.Case, async: false

  alias Aiur.RepoBase

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-repobase-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    origin = init_origin(Path.join(root, "origin"))
    base = Path.join(root, "base")

    {:ok, root: root, origin: origin, base: base}
  end

  describe "refresh/3" do
    test "clones the base and runs base_setup on first build", %{origin: origin, base: base} do
      calls = Path.join(base, "calls.log")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "echo built >> calls.log")
      assert File.dir?(Path.join(base, ".git"))
      assert File.read!(Path.join(base, "README.md")) == "v1\n"
      assert File.exists?(Path.join(base, ".aiur-base-built"))
      assert line_count(calls) == 1
    end

    test "re-runs base_setup after main advances", %{origin: origin, base: base} do
      calls = Path.join(base, "calls.log")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "echo built >> calls.log")
      commit(origin, "v2\n")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "echo built >> calls.log")
      assert File.read!(Path.join(base, "README.md")) == "v2\n"
      assert head(base) == head(origin)
      assert line_count(calls) == 2
    end

    test "skips base_setup when main has not advanced", %{origin: origin, base: base} do
      calls = Path.join(base, "calls.log")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "echo built >> calls.log")
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "echo built >> calls.log")

      assert line_count(calls) == 1
    end

    test "maintains the checkout without building when base_setup is nil", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, nil)
      assert File.dir?(Path.join(base, ".git"))
      assert File.read!(Path.join(base, "README.md")) == "v1\n"
      refute File.exists?(Path.join(base, "calls.log"))
    end

    test "surfaces a base_setup failure", %{origin: origin, base: base} do
      assert {:error, {:base_setup_failed, 7, _out}} = RepoBase.refresh(base, origin, "exit 7")
      # A failed build must not be marked complete, so the next refresh retries it.
      refute File.exists?(Path.join(base, ".aiur-base-built"))
    end
  end

  describe "base_path/1" do
    test "derives an owner/name slug under the configured root" do
      previous = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, "/tmp/aiur-bases")
      on_exit(fn -> restore_env(:repo_base_root, previous) end)

      assert RepoBase.base_path("https://github.com/its-everdred/aiur.git") ==
               "/tmp/aiur-bases/its-everdred/aiur"
    end
  end

  # ---- helpers ----

  defp init_origin(dir) do
    File.mkdir_p!(dir)
    git!(["init", "-b", "main"], dir)
    git!(["config", "user.email", "test@example.com"], dir)
    git!(["config", "user.name", "Test"], dir)
    File.write!(Path.join(dir, "README.md"), "v1\n")
    git!(["add", "."], dir)
    git!(["commit", "-m", "init"], dir)
    dir
  end

  defp commit(dir, content) do
    File.write!(Path.join(dir, "README.md"), content)
    git!(["add", "."], dir)
    git!(["commit", "-m", "update"], dir)
  end

  defp head(dir), do: git!(["rev-parse", "HEAD"], dir) |> String.trim()

  defp git!(args, cwd) do
    {out, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp line_count(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> length()
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
