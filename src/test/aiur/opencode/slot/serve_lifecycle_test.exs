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
end
