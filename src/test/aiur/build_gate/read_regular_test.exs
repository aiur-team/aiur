defmodule Aiur.BuildGate.ReadRegularTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildGate

  # Sources only process.bash with a stub fail helper. A python3 shim on PATH
  # records any call: the wait loop polls this reader, so it must stay Bash
  # builtins rather than an interpreter start per read (#4792).
  @script """
  aiur_build_gate_fail() { printf 'fail reason=%s\\n' "$1"; }
  source "$1"
  aiur_build_gate_read_regular "$2"
  printf 'status=%s\\n' "$?"
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-read-regular-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    shim = Path.join(dir, "bin/python3")
    File.write!(shim, "#!/bin/sh\ntouch \"$0.called\"\nexit 1\n")
    File.chmod!(shim, 0o755)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "prints a regular file's contents", %{dir: dir} do
    path = Path.join(dir, "status")
    File.write!(path, "0 1\n")
    assert read(dir, path) == "0 1\nstatus=0\n"
  end

  test "a missing file is absent, not a failure", %{dir: dir} do
    assert read(dir, Path.join(dir, "missing")) == "status=1\n"
  end

  test "refuses a symlink, even to a regular file", %{dir: dir} do
    target = Path.join(dir, "target")
    File.write!(target, "0 1\n")
    link = Path.join(dir, "link")
    File.ln_s!(target, link)
    assert read(dir, link) == "fail reason=metadata_not_regular\nstatus=125\n"
  end

  test "refuses a FIFO without blocking", %{dir: dir} do
    fifo = Path.join(dir, "fifo")
    assert {"", 0} = System.cmd("mkfifo", [fifo])
    assert read(dir, fifo) == "fail reason=metadata_not_regular\nstatus=125\n"
  end

  test "refuses a directory", %{dir: dir} do
    assert read(dir, dir) == "fail reason=metadata_not_regular\nstatus=125\n"
  end

  test "refuses a file of 4096 bytes or more", %{dir: dir} do
    path = Path.join(dir, "large")
    File.write!(path, String.duplicate("x", 4095))
    assert read(dir, path) == String.duplicate("x", 4095) <> "\nstatus=0\n"
    File.write!(path, String.duplicate("x", 4096))
    assert read(dir, path) == "fail reason=metadata_not_regular\nstatus=125\n"
  end

  defp read(dir, path) do
    process_bash = Path.join(Path.dirname(BuildGate.hook_path()), "build_gate/process.bash")
    bash = System.find_executable("bash")

    {output, 0} =
      System.cmd("timeout", ["5", bash, "-c", @script, "_", process_bash, path], env: [{"PATH", Path.join(dir, "bin") <> ":/usr/bin:/bin"}, {"BASH_ENV", nil}])

    refute File.exists?(Path.join(dir, "bin/python3.called"))
    output
  end
end
