defmodule Aiur.Claude.HookSpoolTest do
  use ExUnit.Case, async: false
  alias Aiur.Claude.{HookEvents, HookSettings}
  alias Aiur.SessionHandle

  setup do
    dir = Path.join(System.tmp_dir!(), "hook-replay-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:aiur, :runtime_state_dir)
    File.mkdir_p!(dir)
    Application.put_env(:aiur, :runtime_state_dir, dir)

    on_exit(fn ->
      if prior, do: Application.put_env(:aiur, :runtime_state_dir, prior), else: Application.delete_env(:aiur, :runtime_state_dir)
      File.rm_rf!(dir)
    end)

    id = "HOOK-#{System.unique_integer([:positive])}"
    :ok = HookEvents.subscribe(id)
    {:ok, path} = HookSettings.spool_path(id)
    File.mkdir_p!(Path.dirname(path))
    %{id: id, path: path}
  end

  defp event(name, key), do: %{"hook_event_name" => name, "session_id" => "s1", "aiur_hook_id" => key}
  defp line(raw), do: Jason.encode!(raw) <> "\n"

  test "replays offline hooks in order and preserves the cursor when saving a thread", %{id: id, path: path} do
    bytes = Enum.map_join([event("UserPromptSubmit", "1"), event("PostToolUse", "2"), event("Stop", "3")], &line/1)
    File.write!(path, bytes)
    assert {:ok, offset} = HookEvents.replay(id, 0)
    assert offset == byte_size(bytes)
    assert_received {:claude_hook, ^id, %{event: :user_prompt_submit}}
    assert_received {:claude_hook, ^id, %{event: :post_tool_use}}
    assert_received {:claude_hook, ^id, %{event: :stop}}
    :ok = SessionHandle.save(id, %{backend: "claude-repl", thread_id: "s1"})
    assert SessionHandle.hook_cursor(id)["offset"] == offset
    assert {:ok, ^offset} = HookEvents.replay(id, 0)
    refute_received {:claude_hook, ^id, _}
  end

  test "posted and spooled events are delivered once, including delayed POSTs", %{id: id, path: path} do
    raw = event("Stop", "one")
    File.write!(path, line(raw))
    assert :ok = HookEvents.dispatch(id, raw)
    assert {:ok, _offset} = HookEvents.replay(id, 0)
    assert_received {:claude_hook, ^id, %{event: :stop}}
    assert {:ok, _offset} = HookEvents.replay(id, 0)
    assert :ok = HookEvents.dispatch(id, raw)
    refute_received {:claude_hook, ^id, _}
  end

  test "a POST before the turn consumer attaches leaves the Stop pending", %{id: id, path: path} do
    :ok = HookEvents.unsubscribe(id)
    raw = event("Stop", "during-restart")
    File.write!(path, line(raw))
    assert :ok = HookEvents.dispatch(id, raw)
    assert SessionHandle.hook_cursor(id)["offset"] == 0
    :ok = HookEvents.subscribe(id)
    assert {:ok, offset} = HookEvents.replay(id, 0)
    assert offset == File.stat!(path).size
    assert_received {:claude_hook, ^id, %{event: :stop}}
  end

  test "skips corrupt lines and holds partial lines until their newline arrives", %{id: id, path: path} do
    bytes = "bad json\n" <> Jason.encode!(event("Stop", "partial"))
    File.write!(path, bytes)
    assert {:ok, 9} = HookEvents.replay(id, 0)
    refute_received {:claude_hook, ^id, _}
    File.write!(path, "\n", [:append])
    assert {:ok, offset} = HookEvents.replay(id, 0)
    assert offset == byte_size(bytes) + 1
    assert_received {:claude_hook, ^id, %{event: :stop}}
  end

  test "rotation starts a new cursor and repeated payloads keep distinct identities", %{id: id, path: path} do
    File.write!(path, line(event("PostToolUse", "old")))
    assert {:ok, _offset} = HookEvents.replay(id, 0)
    assert_received {:claude_hook, ^id, %{event: :post_tool_use}}
    File.write!(path <> ".new", line(event("PostToolUse", "new")))
    File.rename!(path <> ".new", path)
    assert {:ok, offset} = HookEvents.replay(id, 0)
    assert offset == File.stat!(path).size
    assert_received {:claude_hook, ^id, %{event: :post_tool_use}}
    assert :ok = HookEvents.clear_spool(id)
    assert File.read!(path) == ""
  end
end
