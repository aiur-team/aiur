defmodule Aiur.Orchestrator.StatusUsagePauseTest do
  use Aiur.TestSupport

  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.{Slots, State, StatusReason, StatusReport}

  # #7879: with every backend limited, a provider-limit pause holds no fleet
  # slot and its status reason names each backend's state.
  test "a provider-limit pause frees its slot and names every backend's state" do
    # The shared fixture has no `agent.priority` key, so write it in place of `kind`.
    path = Workflow.workflow_file_path()
    write_workflow_file!(path)
    File.write!(path, String.replace(File.read!(path), "agent:\n  kind: \"codex\"", "agent:\n  priority: [codex, claude]"))
    :ok = Aiur.WorkflowStore.force_reload(5_000)
    reset_at = DateTime.utc_now() |> DateTime.add(7_200, :second) |> DateTime.to_iso8601()
    ledger = %{"backends" => Map.new(["codex", "claude"], &{&1, %{"limited" => true, "reset_at" => reset_at}})}
    File.write!(ModelAvailability.path(), Jason.encode!(ledger))

    issue = %Issue{id: "1", identifier: "repo#1", state: "in-progress", title: "Limited"}
    entry = %{identifier: "repo#1", issue: issue, control: %{status: :paused}, paused_reason: :usage_limit_exhausted, started_at: DateTime.utc_now()}
    state = %State{max_concurrent_agents: 1, running: %{"1" => entry}}

    assert Slots.available_slots(state) == 1
    assert [%{identifier: "repo#1", reason: reason}] = StatusReport.agent_statuses(state)
    assert StatusReason.render(reason) == "provider limit; codex limited, claude limited"
  end
end
