defmodule Aiur.Orchestrator.DispatchOutcomeTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.ResourceStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.{CapacityBinding, DispatchOutcome, Slots, State}

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "sym")
    ResourceStore.reset()
    on_exit(fn -> File.write!(path, original) end)
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "dashboard selection label renders its sample age and stale marker" do
    now = DateTime.utc_now()
    hold = %{reasons: [:unknown], candidates: 1, measured_at: DateTime.add(now, -600, :second)}
    binding = CapacityBinding.binding(%{available: 12, dispatch_selection_hold: hold}, %{}, now)
    assert {:dispatch_selection, %{stale_sample?: true}} = binding
    assert CapacityBinding.sample_age_seconds(hold, now) == 600
    label = CapacityBinding.short_label(binding)
    assert label =~ ~r/sampled=\d+s ago STALE/
    assert label =~ "unknown"
  end

  test "unexplained empty selection preserves unknown instead of inventing an upstream cause" do
    issue = %Issue{id: "unknown-2980", identifier: "repo#2980", title: "Ready", state: "todo"}
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}
    owner = self()
    recorded = DispatchOutcome.record(state, state, [issue], &send(owner, {:diagnostic, &1}))
    assert recorded.dispatch_selection_hold.reasons == [:unknown]
    assert_receive {:diagnostic, message}, 1_000
    assert message =~ "despite free slots"
    assert {:dispatch_selection, %{reasons: [:unknown]}} = CapacityBinding.binding(Slots.max_concurrent_agent_status(recorded))
    assert DispatchOutcome.record(recorded, recorded, [], fn _ -> :ok end).dispatch_selection_hold == nil
  end

  test "dependency-held ticket does not make an unrelated ready ticket look dependency-held" do
    held = %Issue{id: "1", identifier: "repo#1", title: "Blocked", state: "todo", dispatch_authorized?: true}
    ready = %Issue{id: "ready-2", identifier: "repo#2", title: "Ready", state: "todo", dispatch_authorized?: true}
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}
    ResourceStore.put_resource(ResourceStore.key(:issue_blocked_by, "owner", "repo", held.id), [%{"number" => 9, "state" => "open", "labels" => [%{"name" => "sym:todo"}]}])
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", "9"), %{"number" => 9, "state" => "open", "labels" => [%{"name" => "sym:todo"}]})

    recorded = DispatchOutcome.record(state, state, [held, ready], fn _ -> :ok end)

    assert recorded.dispatch_selection_hold.reasons == [:unknown]
    assert recorded.dispatch_selection_hold.candidates == 1
    assert recorded.dispatch_declines[held.id] == :dependency
    assert recorded.dispatch_declines[ready.id] == :unknown
  end

  test "a foreign terminal label does not remove an active ticket from selection" do
    issue = %Issue{id: "foreign-3", identifier: "repo#3", title: "Ready", state: "todo", labels: ["sym:todo", "agent:done"], state_labels: ["todo"], dispatch_authorized?: true}
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}

    recorded = DispatchOutcome.record(state, state, [issue], fn _ -> :ok end)

    assert recorded.dispatch_declines[issue.id] == :unknown
    assert recorded.dispatch_selection_hold.candidates == 1
  end
end
