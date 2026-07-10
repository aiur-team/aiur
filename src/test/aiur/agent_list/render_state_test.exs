defmodule Aiur.AgentList.RenderStateTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.{RenderState, State}

  @renderer_keys ~w[
    summaries selection_index selection_focus help_visible? max_agents_alert? columns rows project_label
    dashboard_url agent_kind agent_count max_agents visible_sessions debug_mode? perf_summary warmth_events
    debug_events attach_state started_slots fully_warmed_slots opened_panes agents_with_content
    latest_event_by_id phase_by_identifier open_attentions_by_id progress_by_id warm_status_dark_mode?
    remote_control_hint prewarm_active? prewarm_phase truecolor?
  ]a

  test "build returns every renderer-consumed key" do
    state = State.new(command_template: "cmd")
    render_state = RenderState.build(state)

    for key <- @renderer_keys do
      assert Map.has_key?(render_state, key), "missing #{inspect(key)}"
    end
  end

  test "build computes active non-paused agent count from summaries" do
    state =
      State.new(command_template: "cmd")
      |> Map.put(:summaries, [
        %{status: :running, work_state: :working},
        %{status: :running, work_state: :paused},
        %{status: :queued, work_state: :working}
      ])

    assert RenderState.build(state).agent_count == 1
  end

  test "max_agents comes only from positive cached poll_state and never calls orchestrator" do
    raising = fn -> raise "orchestrator must not be called" end

    base =
      State.new(command_template: "cmd", orchestrator: raising)
      |> put_in([:poll_state, :max_concurrent_agents], 3)

    assert RenderState.build(base).max_agents == 3

    assert nil ==
             base
             |> put_in([:poll_state, :max_concurrent_agents], 0)
             |> RenderState.build()
             |> Map.fetch!(:max_agents)

    assert nil ==
             base
             |> put_in([:poll_state, :max_concurrent_agents], "3")
             |> RenderState.build()
             |> Map.fetch!(:max_agents)
  end
end
