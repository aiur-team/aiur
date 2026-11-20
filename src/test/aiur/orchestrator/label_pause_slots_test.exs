defmodule Aiur.Orchestrator.LabelPauseSlotsTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{PauseResume, Slots, State}

  defp entry(id, status, reason \\ nil) do
    %{
      pid: self(),
      identifier: id,
      issue: %Aiur.Issue{id: id, identifier: id, title: id, state: "in-progress", state_labels: ["in-progress"], labels: ["agent:in-progress"]},
      control: %{status: status},
      paused_reason: reason,
      worker_host: nil
    }
  end

  defp state(paused_reason) do
    running = %{"work" => entry("work", :working), "paused" => entry("paused", :paused, paused_reason)}
    %State{max_concurrent_agents: 2, effective_concurrent_agents: 2, running: running}
  end

  test "a label-paused ticket frees a slot for a third ready ticket" do
    s = state(:label_override)
    assert Slots.used_slots(s) == 1
    assert Slots.available_slots(s) == 1
  end

  test "an operator pause still reserves its slot" do
    s = state(:operator_pause)
    assert Slots.used_slots(s) == 2
    assert Slots.available_slots(s) == 0
  end

  test "removing the label does not exceed the cap when the fleet is full" do
    paused = entry("paused", :paused, :label_override)
    running = %{"a" => entry("a", :working), "b" => entry("b", :working), "paused" => paused}
    s = %State{max_concurrent_agents: 2, effective_concurrent_agents: 2, running: running}

    assert {:error, :max_concurrent_agents_reached} = PauseResume.resume_paused_issue_preflight(s, paused)
  end

  test "removing the label resumes when a slot is free" do
    s = state(:label_override)
    assert :ok = PauseResume.resume_paused_issue_preflight(s, s.running["paused"])
  end
end
