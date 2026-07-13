defmodule Aiur.FsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.Fs

  test "writes contents readable at path and returns :ok", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "record.txt")

    assert :ok = Fs.atomic_write(path, "contents")
    assert File.read!(path) == "contents"
  end

  test "overwrites an existing file's previous contents", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "record.txt")
    File.write!(path, "old")

    assert :ok = Fs.atomic_write(path, "new")
    assert File.read!(path) == "new"
  end

  test "fsync: true writes identical contents and returns :ok", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "durable.txt")

    assert :ok = Fs.atomic_write(path, "contents", fsync: true)
    assert File.read!(path) == "contents"
  end

  test "successful write leaves no sibling temp files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "cleanup.txt")

    assert :ok = Fs.atomic_write(path, "contents")
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "returns {:error, :enoent} without a parent directory and leaves no temp file", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "missing", "record.txt"])

    assert {:error, :enoent} = Fs.atomic_write(path, "contents")
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "two sequential writes both succeed and file holds second contents", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "record.txt")

    assert :ok = Fs.atomic_write(path, "first")
    assert :ok = Fs.atomic_write(path, "second")
    assert File.read!(path) == "second"
  end

  test "sync_filesystem/0 succeeds" do
    assert :ok = Fs.sync_filesystem()
  end
end
