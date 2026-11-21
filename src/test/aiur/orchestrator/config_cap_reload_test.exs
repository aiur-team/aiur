defmodule Aiur.Orchestrator.ConfigCapReloadTest do
  # open-games 2026-11-14: a `set max-agents 10` from days earlier was restored
  # from the control journal at every boot, and as the session override it
  # outranked `.aiur/config`, so edits 10 -> 7 -> 6 -> 4 never applied. An edit to
  # the configured cap is the operator's newer intent and must take effect.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.ControlLifecycleStore
  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Workflow

  setup do
    path = Aiur.TestSupport.tmp_root!("aiur-config-cap-reload") <> ".json"
    previous = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, path)
    :ok = ControlLifecycleStore.update_checked(&%{&1 | max_agents: 10})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :control_lifecycle_store_path, previous),
        else: Application.delete_env(:aiur, :control_lifecycle_store_path)

      Aiur.TestCleanup.rm_rf!(path)
      Aiur.TestCleanup.rm_rf!(path <> ".lock")
    end)

    :ok
  end

  test "an edit to the configured cap replaces a restored max-agents override" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 7)
    state = %State{max_concurrent_agents: 10, session_max_concurrent_agents: 10}

    state = Lifecycle.refresh_runtime_config(state)

    assert Slots.max_concurrent_agent_limit(state) == 7
    assert state.session_max_concurrent_agents == nil
    # Cleared in the journal too, or the next boot restores the stale cap.
    assert ControlLifecycleStore.load().max_agents == nil
  end

  test "an unchanged configured cap keeps the max-agents override" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 10)
    state = %State{max_concurrent_agents: 10, session_max_concurrent_agents: 6}

    state = Lifecycle.refresh_runtime_config(state)

    assert Slots.max_concurrent_agent_limit(state) == 6
    assert ControlLifecycleStore.load().max_agents == 10
  end
end
