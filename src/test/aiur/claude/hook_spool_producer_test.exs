defmodule Aiur.Claude.HookSpoolProducerTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.HookSettings

  setup do
    root = Path.join(System.tmp_dir!(), "claude-hook-producer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Aiur.TestSupport.put_runtime_state_dir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    input = Path.join(root, "input.json")
    File.write!(input, Jason.encode!(%{"hook_event_name" => "Stop", "session_id" => "claude-session"}))
    {:ok, root: root, input: input}
  end

  test "dashboard outage leaves a compact event in the durable spool and exits silently", %{input: input} do
    command = HookSettings.hook_command("MT/9", "http://127.0.0.1:1")
    assert {"", 0} = System.cmd("sh", ["-c", "(" <> command <> ") < " <> shell_quote(input)])
    {:ok, path} = HookSettings.spool_path("MT/9")
    assert Path.basename(path) == "MT_9.ndjson"
    assert [line] = File.read!(path) |> String.split("\n", trim: true)
    assert %{"hook_event_name" => "Stop", "session_id" => "claude-session", "aiur_hook_id" => id} = Jason.decode!(line)
    assert byte_size(id) == 32
  end

  test "spool exists before POST and both deliveries carry the same unique event", %{root: root, input: input} do
    {:ok, path} = HookSettings.spool_path("101")
    curl = Path.join(root, "curl")
    posted = Path.join(root, "posted.json")
    File.write!(curl, "#!/bin/sh\ntest -s \"$SPOOL\" || exit 9\ncat > \"$POSTED\"\nexit 7\n")
    File.chmod!(curl, 0o700)
    command = HookSettings.hook_command("101", "http://127.0.0.1:1")
    env = [{"PATH", root <> ":" <> System.get_env("PATH")}, {"SPOOL", path}, {"POSTED", posted}]

    for _ <- 1..2 do
      assert {"", 0} = System.cmd("sh", ["-c", "(" <> command <> ") < " <> shell_quote(input)], env: env)
      assert File.read!(path) |> String.split("\n", trim: true) |> List.last() == String.trim(File.read!(posted))
    end

    ids = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["aiur_hook_id"])
    assert length(Enum.uniq(ids)) == 2
  end

  test "capacity rotation and session reset replace the inode", %{input: input} do
    {:ok, path} = HookSettings.spool_path("101")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("x", 16 * 1024 * 1024))
    {:ok, before} = File.stat(path)
    helper = Application.app_dir(:aiur, "priv/claude_hook_spool.py")
    command = "python3 " <> shell_quote(helper) <> " " <> shell_quote(path) <> " < " <> shell_quote(input)
    {payload, 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: false)
    assert File.read!(path) == payload
    assert Jason.decode!(payload)["hook_event_name"] == "Stop"
    {:ok, rotated} = File.stat(path)
    refute rotated.inode == before.inode

    assert {"", 0} = System.cmd("python3", [helper, "--reset", path])
    assert File.read!(path) == ""
    {:ok, reset} = File.stat(path)
    refute reset.inode == rotated.inode
  end

  test "settings refuse to launch hooks without the spool's Python prerequisite", %{root: root} do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, :claude_hook_spool_requires_python3} = HookSettings.write("101", "http://127.0.0.1:1")
    after
      System.put_env("PATH", previous_path)
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
