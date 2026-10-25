defmodule Aiur.AgentCompaction.HandoffTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentCompaction.Handoff
  alias Aiur.AgentCompaction.Store
  alias Aiur.Config.Schema.Compaction

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur_compaction_handoff_test")
    previous = Application.get_env(:aiur, :agent_compaction_state_dir)
    Application.put_env(:aiur, :agent_compaction_state_dir, dir)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :agent_compaction_state_dir)
      else
        Application.put_env(:aiur, :agent_compaction_state_dir, previous)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "reports and persists unsupported providers once for an unchanged thread", %{dir: dir} do
    config = %Compaction{enabled: true, manual_approval: true}
    session = %{backend: "claude", thread_id: "thread-1"}
    callback = fn status, thread_id, _detail -> send(self(), {:status, status, thread_id}) end

    assert :ok = Handoff.execute("human-review", session, "issue-1", 4, config, nil, callback)
    assert_received {:status, :unsupported, "thread-1"}
    assert {:ok, %{"thread_id" => "thread-1", "status" => "unsupported"}} = Store.load("issue-1", dir: dir)

    assert :ok = Handoff.execute("human-review", session, "issue-1", 4, config, nil, callback)
    refute_received {:status, :unsupported, "thread-1"}
  end

  test "does not report Codex as unsupported when its backend is not enabled" do
    config = %Compaction{enabled: true, manual_approval: true}
    session = %{backend: "codex", thread_id: "thread-1"}
    callback = fn status, thread_id, _detail -> send(self(), {:status, status, thread_id}) end

    assert :ok = Handoff.execute("human-review", session, "issue-1", 4, config, nil, callback)
    refute_received {:status, :unsupported, "thread-1"}
  end
end
