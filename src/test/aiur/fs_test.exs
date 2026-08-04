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

  test "quarantine suffixes stay unique across separate boots so forensic archives never collide", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "record.txt")

    # Two separate boots: each fresh BEAM resets the VM-scoped unique_integer
    # counter, which is exactly the window where the old .corrupt-<n> suffix
    # would collide and the second rename would overwrite the first archive.
    File.write!(path, "first-boot bytes")
    assert {_out1, 0} = quarantine_in_fresh_beam(path)

    File.write!(path, "second-boot bytes")
    assert {_out2, 0} = quarantine_in_fresh_beam(path)

    archives = Path.wildcard(path <> ".corrupt-*")
    assert length(archives) == 2

    # every boot's bytes survive under a distinct timestamped archive
    assert archives |> Enum.map(&File.read!/1) |> Enum.sort() ==
             ["first-boot bytes", "second-boot bytes"]
  end

  defp quarantine_in_fresh_beam(path) do
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    timeout = System.find_executable("timeout") || raise "timeout executable not found"

    code = """
    path = System.fetch_env!("QUARANTINE_PATH")
    :ok = Aiur.Fs.quarantine(path)
    IO.puts("quarantined=" <> Path.basename(path))
    """

    System.cmd(timeout, ["20", executable, "-pa", Application.app_dir(:aiur, "ebin"), "-e", code],
      env: [{"QUARANTINE_PATH", path}, {"ERL_FLAGS", "+S 1:1"}],
      stderr_to_stdout: true
    )
  end
end
