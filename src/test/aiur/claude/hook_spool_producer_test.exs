defmodule Aiur.Claude.HookSpoolProducerTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.{HookEvents, HookSettings, Repl.Reaper}
  alias Aiur.Tmux

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

  test "tool inputs and responses reach neither the spool nor the forwarded payload", %{root: root, input: input} do
    marker = "credential-marker-must-not-persist"
    event = %{"hook_event_name" => "PostToolUse", "tool_name" => "Bash", "tool_input" => %{"command" => marker}, "tool_response" => marker, "unexpected" => marker}
    File.write!(input, Jason.encode!(event))
    posted = post_hook(root, input, "redacted")
    {:ok, spool} = HookSettings.spool_path("redacted")
    refute File.read!(spool) =~ marker
    refute posted =~ marker
    assert Map.keys(Jason.decode!(posted)) |> Enum.sort() == ~w(aiur_hook_id hook_event_name tool_name)
    assert Jason.decode!(posted)["tool_name"] == "Bash"
    assert String.trim(File.read!(spool)) == String.trim(posted)
  end

  test "a failed spool append still posts and dispatches the live event", %{root: root, input: input} do
    {:ok, spool} = HookSettings.spool_path("unwritable")
    File.mkdir_p!(spool)
    posted = post_hook(root, input, "unwritable") |> Jason.decode!()
    refute Map.has_key?(posted, "aiur_hook_id")
    assert :ok = HookEvents.subscribe("unwritable")
    assert :ok = HookEvents.dispatch("unwritable", posted)
    assert_receive {:claude_hook, "unwritable", %{event: :stop, session_id: "claude-session"}}, 1_000
  end

  test "proven session teardown removes its persisted hook payload", %{root: root, input: input} do
    post_hook(root, input, "ending")
    {:ok, spool} = HookSettings.spool_path("ending")
    assert File.exists?(spool)
    tmux = start_supervised!({Tmux, name: __MODULE__, transport: {:mock, self()}})
    task = Task.async(fn -> Reaper.stop_session(%{tmux: tmux, pane_id: "%90", os_pid: 2_147_480_000, identifier: "ending"}) end)
    assert {:ok, :cleanup_proven} = finish_cleanup(tmux, task)
    refute File.exists?(spool)
  end

  defp post_hook(root, input, identifier) do
    curl = Path.join(root, "curl")
    posted = Path.join(root, "posted.json")
    File.write!(curl, "#!/bin/sh\ncat > \"$POSTED\"\n")
    File.chmod!(curl, 0o700)
    env = [{"PATH", root <> ":" <> System.get_env("PATH")}, {"POSTED", posted}]
    command = HookSettings.hook_command(identifier, "http://127.0.0.1:1")
    assert {"", 0} = System.cmd("sh", ["-c", "(" <> command <> ") < " <> shell_quote(input)], env: env)
    File.read!(posted)
  end

  defp finish_cleanup(tmux, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        send(tmux, {:tmux_mock_data, "%begin 1 1 0\nno pane\n%error 1 1 0\n"})
        finish_cleanup(tmux, task)

      {:tmux_mock_out, "kill-pane" <> _} ->
        send(tmux, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
        finish_cleanup(tmux, task)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      2_000 -> flunk("session cleanup did not finish")
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
