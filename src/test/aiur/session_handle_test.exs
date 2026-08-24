defmodule Aiur.SessionHandleTest do
  use ExUnit.Case, async: true

  alias Aiur.SessionHandle

  # Pinned so the handle filename never depends on the ambient
  # `Paths.repo_name/0`, which reads the shared workflow config. A concurrent
  # async test that rewrites the workflow file (changing tracker kind/repo)
  # flips `repo_name/0` between a save and a load, making the load look in a
  # different file and return `:none` — the #1920 flake. Pinning the repo name
  # here (the same injection seam `dir`/`hostname` already use) makes the path
  # deterministic regardless of what sibling tests do.
  @repo_name "session-test"

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur_session_handle_test")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "save/3 + load/3 round-trip" do
    test "a saved handle loads back with the same backend and thread_id", %{dir: dir} do
      :ok =
        SessionHandle.save(
          "378",
          %{backend: "codex", thread_id: "thr_abc"},
          dir: dir,
          hostname: "box-1",
          repo_name: @repo_name
        )

      assert {:ok, handle} = SessionHandle.load("378", "codex", dir: dir, hostname: "box-1", repo_name: @repo_name)
      assert handle.thread_id == "thr_abc"
      assert handle.backend == "codex"
      assert handle.hostname == "box-1"
    end

    test "a re-save overwrites the prior thread_id", %{dir: dir} do
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "old"}, dir: dir, hostname: "h", repo_name: @repo_name)
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "new"}, dir: dir, hostname: "h", repo_name: @repo_name)
      assert {:ok, %{thread_id: "new"}} = SessionHandle.load("9", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "identifiers with path-unsafe characters are sanitized into one file", %{dir: dir} do
      :ok = SessionHandle.save("feat/x", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h", repo_name: @repo_name)
      assert {:ok, %{thread_id: "t"}} = SessionHandle.load("feat/x", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end
  end

  describe "load/3 degrades to :none (safe clean-start fallback)" do
    test "a missing handle file is :none", %{dir: dir} do
      assert :none == SessionHandle.load("absent", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "a backend mismatch is :none (never resume a different backend's thread)", %{dir: dir} do
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h", repo_name: @repo_name)
      assert :none == SessionHandle.load("9", "claude", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "a hostname mismatch is :none (codex rollouts are host-local)", %{dir: dir} do
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "box-1", repo_name: @repo_name)
      assert :none == SessionHandle.load("9", "codex", dir: dir, hostname: "box-2", repo_name: @repo_name)
    end

    test "a corrupt (non-JSON) handle file is :none, not a crash", %{dir: dir} do
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h", repo_name: @repo_name)
      path = SessionHandle.path_for("9", dir: dir, repo_name: @repo_name)
      File.write!(path, "{not json")
      assert :none == SessionHandle.load("9", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "an unknown schema_version is :none (forward-incompatible handle)", %{dir: dir} do
      path = SessionHandle.path_for("9", dir: dir, repo_name: @repo_name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"schema_version" => 999, "backend" => "codex", "thread_id" => "t", "hostname" => "h"}))
      assert :none == SessionHandle.load("9", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "a handle missing the thread_id is :none", %{dir: dir} do
      path = SessionHandle.path_for("9", dir: dir, repo_name: @repo_name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"schema_version" => 1, "backend" => "codex", "hostname" => "h"}))
      assert :none == SessionHandle.load("9", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end
  end

  describe "clear/2" do
    test "removes a saved handle so the next load is :none", %{dir: dir} do
      :ok = SessionHandle.save("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h", repo_name: @repo_name)
      :ok = SessionHandle.clear("9", dir: dir, repo_name: @repo_name)
      assert :none == SessionHandle.load("9", "codex", dir: dir, hostname: "h", repo_name: @repo_name)
    end

    test "is idempotent on an absent handle", %{dir: dir} do
      assert :ok == SessionHandle.clear("never-existed", dir: dir, repo_name: @repo_name)
    end
  end
end
