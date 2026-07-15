defmodule Aiur.Orchestrator.PauseResumeTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{PauseResume, State}

  test "sets control status only for a known running entry" do
    state = %State{running: %{"known" => %{control: %{status: :working}}}}

    updated_state = PauseResume.put_running_control_status(state, "known", :paused)

    assert get_in(updated_state.running, ["known", :control, :status]) == :paused
    assert PauseResume.put_running_control_status(state, "missing", :paused) == state
  end

  test "resets the Codex timestamp for a known entry" do
    now = DateTime.utc_now()
    running = %{"known" => %{last_codex_timestamp: nil}}

    assert get_in(PauseResume.reset_last_codex_timestamp(running, "known", now), ["known", :last_codex_timestamp]) == now
    assert PauseResume.reset_last_codex_timestamp(running, "missing", now) == running
  end

  test "only an operator resume resets a max-duration clock" do
    started_at = DateTime.add(DateTime.utc_now(), -60, :second)
    now = DateTime.utc_now()
    running = %{"capped" => %{started_at: started_at, paused_reason: :max_agent_duration}}

    assert %{started_at: ^now} = PauseResume.reset_duration_clock_if_capped(running, "capped", now, true)["capped"]
    refute Map.has_key?(PauseResume.reset_duration_clock_if_capped(running, "capped", now, true)["capped"], :paused_reason)

    assert %{started_at: ^started_at} = PauseResume.reset_duration_clock_if_capped(running, "capped", now, false)["capped"]
    refute Map.has_key?(PauseResume.reset_duration_clock_if_capped(running, "capped", now, false)["capped"], :paused_reason)
  end

  test "preserves unrelated pause markers on resume" do
    running = %{"paused" => %{paused_reason: :operator}}

    assert PauseResume.reset_duration_clock_if_capped(running, "paused", DateTime.utc_now(), true) == running
  end

  test "completed replacement preserves state committed by a rejected admission" do
    issue = %Aiur.Issue{id: "known", identifier: "repo#known", state: "in-progress"}

    running_entry = %{
      issue: issue,
      identifier: issue.identifier,
      completed_provenance: true,
      control: %{status: :completed}
    }

    state = %State{
      running: %{issue.id => running_entry},
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1
    }

    rejected = %{state | claimed: MapSet.new(["durably-tripped"])}

    assert ^rejected =
             PauseResume.dispatch_completed_replacement(state, running_entry, issue,
               admit_fun: fn _state, ^issue, nil ->
                 {:error, :thrash_circuit_open, rejected}
               end,
               replace_fun: fn _, _, _, _ -> flunk("rejected admission must not replace") end
             )
  end
end
