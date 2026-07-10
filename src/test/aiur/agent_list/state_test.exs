defmodule Aiur.AgentList.StateTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.State

  @expected_keys ~w[
    summaries selection_index selection_focus columns rows help_visible? max_agents_alert?
    prewarm_active? prewarm_phase remote_control_hint write_fun pane_manager orchestrator tmux
    command_template rc_pane_borders visible_sessions poll_state debug_mode? attach_state
    started_slots fully_warmed_slots opened_panes agents_with_content latest_event_by_id
    open_attentions_by_id progress_by_id phase_by_identifier warm_status_dark_mode?
    warmth_events perf_summary debug_events
  ]a

  test "new returns the flat AgentList state key set" do
    state = State.new(command_template: "echo open")

    for key <- @expected_keys do
      assert Map.has_key?(state, key), "missing #{inspect(key)}"
    end
  end

  test "new applies default selection and poll state values" do
    state = State.new(command_template: "echo open")

    assert state.selection_index == 0
    assert state.selection_focus == :agents

    assert state.poll_state == %{
             checking?: false,
             next_poll_due_at_ms: nil,
             max_concurrent_agents: nil
           }
  end

  test "new applies dependency options to corresponding keys" do
    write_fun = fn _iodata -> :ok end

    state =
      State.new(
        command_template: "cmd",
        write_fun: write_fun,
        pane_manager: :pane_manager,
        orchestrator: :orchestrator,
        tmux: :tmux,
        debug?: true
      )

    assert state.write_fun == write_fun
    assert state.pane_manager == :pane_manager
    assert state.orchestrator == :orchestrator
    assert state.tmux == :tmux
    assert state.command_template == "cmd"
    assert state.debug_mode?
  end
end
