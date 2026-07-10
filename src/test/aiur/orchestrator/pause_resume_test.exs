defmodule Aiur.Orchestrator.PauseResumeTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{PauseResume, State}

  test "sets control status only for a known running entry" do
    state = %State{running: %{"known" => %{control: %{status: :working}}}}

    assert get_in(PauseResume.put_running_control_status(state, "known", :paused).running, ["known", :control, :status]) == :paused
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

  test "clears other pause markers on resume" do
    running = %{"paused" => %{paused_reason: :operator}}

    assert PauseResume.reset_duration_clock_if_capped(running, "paused", DateTime.utc_now(), true) == %{"paused" => %{}}
  end
end
