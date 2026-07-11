defmodule Aiur.Opencode.Slot.ServeLifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.Slot.ServeLifecycle

  # --- writers_for_base_url/2 ---

  test "writers_for_base_url returns only entries matching base_url" do
    entries = [
      %{base_url: "http://a:1234", session_id: "s1"},
      %{base_url: "http://b:1234", session_id: "s2"},
      %{base_url: "http://a:1234", session_id: "s3"}
    ]

    result = ServeLifecycle.writers_for_base_url(entries, "http://a:1234")
    assert length(result) == 2
    assert Enum.all?(result, fn e -> e.base_url == "http://a:1234" end)
  end

  test "writers_for_base_url returns empty when no match" do
    entries = [%{base_url: "http://x:1234"}]
    assert [] = ServeLifecycle.writers_for_base_url(entries, "http://y:1234")
  end

  # --- workspace_path_for/1 ---

  test "workspace_path_for returns path ending with opencode-slot-N" do
    path = ServeLifecycle.workspace_path_for(3)
    assert String.ends_with?(path, ".local/share/aiur/opencode-slot-3")
  end

  # --- maybe_run_session_gc/1 ---

  test "maybe_run_session_gc returns :ok for non-slot-1 state" do
    state = %{slot_index: 2, base_url: "http://x"}
    assert :ok = ServeLifecycle.maybe_run_session_gc(state)
  end

  test "maybe_run_session_gc returns :ok for slot-1 (fires background task)" do
    state = %{slot_index: 1, base_url: "http://127.0.0.1:1"}
    assert :ok = ServeLifecycle.maybe_run_session_gc(state)
  end

  # --- teardown_generation/1 ---

  test "teardown_generation with nil state fields returns :ok without external calls" do
    state = %{base_url: nil, server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.teardown_generation(state)
  end

  test "teardown_generation with binary base_url and nil server/pane/token returns :ok" do
    # SessionWriterRegistry.all() returns [] when registry not running; reap is a no-op
    state = %{base_url: "http://127.0.0.1:1", server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.teardown_generation(state)
  end

  test "teardown_generation stops a live server before returning" do
    {:ok, server_pid} = Agent.start_link(fn -> :running end)

    assert :ok =
             ServeLifecycle.teardown_generation(%{
               base_url: nil,
               server_pid: server_pid,
               pane_id: nil,
               token: nil
             })

    refute Process.alive?(server_pid)
  end

  # --- terminate_cleanup/1 ---

  test "terminate_cleanup with nil state fields returns :ok without external calls" do
    state = %{base_url: nil, server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.terminate_cleanup(state)
  end

  test "terminate_cleanup with binary base_url and nil server/pane/token returns :ok" do
    # Same as above: reap_writers_for_base_url on empty registry is a safe no-op
    state = %{base_url: "http://127.0.0.1:1", server_pid: nil, pane_id: nil, token: nil}
    assert :ok = ServeLifecycle.terminate_cleanup(state)
  end

  test "terminate_cleanup tolerates stopping a live server" do
    {:ok, server_pid} = Agent.start_link(fn -> :running end)

    assert :ok =
             ServeLifecycle.terminate_cleanup(%{
               base_url: nil,
               server_pid: server_pid,
               pane_id: nil,
               token: nil
             })

    refute Process.alive?(server_pid)
  end
end
