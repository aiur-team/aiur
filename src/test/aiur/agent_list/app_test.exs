defmodule Aiur.AgentList.AppTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEvents
  alias Aiur.AgentList.App

  defmodule MockPaneManager do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def open_conversation(pid, identifier, command, opts \\ []) do
      GenServer.call(pid, {:open, identifier, command, opts})
    end

    def handle_call({:open, identifier, command, _opts}, _from, parent) do
      send(parent, {:mock_open, identifier, command})
      {:reply, {:ok, "%999"}, parent}
    end

    def handle_call({:attach, _identifier, _command, _opts}, _from, parent) do
      {:reply, {:error, :no_focused_pane}, parent}
    end

    def handle_call(:list, _from, parent), do: {:reply, %{}, parent}

    def handle_call(:toggle_orientation, _from, parent),
      do: {:reply, {:ok, :vertical}, parent}
  end

  defmodule MockOrchestrator do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    def init(parent),
      do:
        {:ok,
         %{
           parent: parent,
           max: 2,
           resume_result: {:ok, :resumed},
           adjust_result: nil,
           rc_result: {:ok, :on}
         }}

    def handle_call(:max_concurrent_agents, _from, state) do
      {:reply, %{active: 0, paused: 0, configured: 2, max: state.max, session_override?: true}, state}
    end

    def handle_call({:pause_agent, identifier}, _from, state) do
      send(state.parent, {:mock_pause, identifier})
      {:reply, {:ok, 101}, state}
    end

    def handle_call({:resume_agent, identifier}, _from, state) do
      send(state.parent, {:mock_resume, identifier})
      {:reply, state.resume_result, state}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, %{adjust_result: nil} = state) do
      send(state.parent, {:mock_adjust_max, delta})
      next = max(state.max + delta, 1)
      state = %{state | max: next}
      {:reply, {:ok, %{active: 0, paused: 0, configured: 2, max: next, session_override?: true}}, state}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, state) do
      send(state.parent, {:mock_adjust_max, delta})
      {:reply, state.adjust_result, state}
    end

    def handle_call({:set_remote_control, identifier, on?}, _from, state) do
      send(state.parent, {:mock_set_remote_control, identifier, on?})
      {:reply, state.rc_result, state}
    end

    def handle_cast({:set_resume_result, result}, state), do: {:noreply, %{state | resume_result: result}}
    def handle_cast({:set_adjust_result, result}, state), do: {:noreply, %{state | adjust_result: result}}
    def handle_cast({:set_rc_result, result}, state), do: {:noreply, %{state | rc_result: result}}
  end

  setup do
    parent = self()
    {:ok, pm} = start_supervised({MockPaneManager, parent})
    {:ok, orchestrator} = start_supervised({MockOrchestrator, parent})

    name = Module.concat(__MODULE__, :"App#{System.unique_integer([:positive])}")

    write_fun = fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end

    {:ok, _pid} =
      start_supervised(
        {App,
         [
           name: name,
           write_fun: write_fun,
           pane_manager: pm,
           orchestrator: orchestrator,
           subscribe?: false,
           command_template: "echo open"
         ]},
        id: name
      )

    %{app: name, pm: pm, orchestrator: orchestrator}
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp send_running_change(app, summaries) do
    send(GenServer.whereis(app), {:running_changed, summaries})
  end

  defp mark_warm(app, identifier) do
    send(GenServer.whereis(app), {:attach_state_changed, identifier, 1, nil})

    wait_until(fn ->
      app
      |> App.snapshot()
      |> Map.get(:attach_state, %{})
      |> Map.get(identifier)
      |> case do
        %{attach_count: n} when n > 0 -> true
        _ -> false
      end
    end)
  end

  test "renders on startup", %{} do
    assert_receive {:rendered, _output}, 500
  end

  test "running_changed populates summaries and re-renders", %{app: app} do
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])
    assert_receive {:rendered, output} when is_binary(output), 500

    assert App.snapshot(app).summaries == [
             %{identifier: "MT-A", status: :running, alert_count: 0}
           ]
  end

  test "navigation forms one continuous ring across agents and the max chip", %{app: app} do
    # Both ↑ from the first row AND ↓ from the last row should land
    # on the max-agents chip. Previously ↓ from the last row wrapped
    # straight back to the first row, which broke the "continuous list"
    # expectation: the operator could only reach the chip by going up.
    send_running_change(app, [
      AgentEvents.agent_summary("MT-A", :running, 0),
      AgentEvents.agent_summary("MT-B", :running, 0)
    ])

    wait_until(fn -> length(App.snapshot(app).summaries) == 2 end)
    :sys.replace_state(GenServer.whereis(app), &%{&1 | selection_focus: :agents, selection_index: 0})

    # First → last
    App.select_next(app)
    wait_until(fn -> App.snapshot(app).selection_index == 1 end)
    assert App.snapshot(app).selection_index == 1
    assert App.snapshot(app).selection_focus == :agents

    # Last → max chip (new behavior; no more silent wrap)
    App.select_next(app)
    wait_until(fn -> App.snapshot(app).selection_focus == :max_agents end)
    assert App.snapshot(app).selection_focus == :max_agents

    # Max chip → first
    App.select_next(app)
    wait_until(fn -> App.snapshot(app).selection_focus == :agents and App.snapshot(app).selection_index == 0 end)
    assert App.snapshot(app).selection_index == 0

    # First → max chip (symmetric)
    App.select_previous(app)
    wait_until(fn -> App.snapshot(app).selection_focus == :max_agents end)
    assert App.snapshot(app).selection_focus == :max_agents

    # Max chip → last
    App.select_previous(app)
    wait_until(fn -> App.snapshot(app).selection_focus == :agents and App.snapshot(app).selection_index == 1 end)
    assert App.snapshot(app).selection_focus == :agents
  end

  test "activate calls PaneManager with the selected identifier and command", %{app: app} do
    send_running_change(app, [AgentEvents.agent_summary("MT-FOCUS", :running, 0)])
    Process.sleep(50)
    mark_warm(app, "MT-FOCUS")

    App.activate(app)

    assert_receive {:mock_open, "MT-FOCUS", "echo open MT-FOCUS"}, 500
  end

  test "space pauses the selected active agent", %{app: app} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-FOCUS", :running, 0), :work_state, :working)
    ])

    Process.sleep(50)

    App.toggle_pause(app)

    assert_receive {:mock_pause, "MT-FOCUS"}, 500
  end

  test "space resumes the selected paused agent", %{app: app} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    Process.sleep(50)

    App.toggle_pause(app)

    assert_receive {:mock_resume, "MT-PAUSED"}, 500
  end

  test "space starts the selected queued agent when capacity is available", %{app: app} do
    send_running_change(app, [AgentEvents.agent_summary("MT-QUEUED", :queued, 0)])
    Process.sleep(50)

    App.toggle_pause(app)

    assert_receive {:mock_resume, "MT-QUEUED"}, 500
  end

  test "resume beyond capacity rings bell and highlights max control", %{app: app, orchestrator: orchestrator} do
    GenServer.cast(orchestrator, {:set_resume_result, {:error, :max_concurrent_agents_reached}})

    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    Process.sleep(50)

    App.toggle_pause(app)

    assert_receive {:mock_resume, "MT-PAUSED"}, 500
    assert_receive {:rendered, "\a"}, 500
    assert App.snapshot(app).max_agents_alert?
  end

  test "any resume failure rings the bell — not just :max_concurrent_agents_reached", %{
    app: app,
    orchestrator: orchestrator
  } do
    # Regression: only the two slot-cap errors used to surface; reasons
    # like :not_resumable, :dispatch_failed, :no_running_agent, or the
    # new :agent_paused were swallowed silently — leaving the operator
    # wondering whether the key even registered.
    GenServer.cast(orchestrator, {:set_resume_result, {:error, :not_resumable}})

    send_running_change(app, [AgentEvents.agent_summary("MT-QUEUED", :queued, 0)])
    Process.sleep(50)

    App.toggle_pause(app)

    assert_receive {:mock_resume, "MT-QUEUED"}, 500
    assert_receive {:rendered, "\a"}, 500
    assert App.snapshot(app).max_agents_alert?
  end

  test "enter opens a paused agent without resuming it", %{app: app} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    Process.sleep(50)
    mark_warm(app, "MT-PAUSED")

    App.activate(app)

    assert_receive {:mock_open, "MT-PAUSED", "echo open MT-PAUSED"}, 500
    refute_receive {:mock_resume, "MT-PAUSED"}, 100
  end

  test "moving above the first row focuses the max control", %{app: app} do
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])
    Process.sleep(50)

    App.select_previous(app)
    Process.sleep(20)

    assert App.snapshot(app).selection_focus == :max_agents

    App.select_next(app)
    Process.sleep(20)

    assert App.snapshot(app).selection_focus == :agents
    assert App.snapshot(app).selection_index == 0
  end

  test "left and right adjust max control regardless of selection focus", %{app: app} do
    # Regression: the keypress used to be gated on `selection_focus == :max_agents`,
    # so ←/→ was silently swallowed when an agent row was selected. The
    # operator perceived the bump as not taking effect. The cast now always
    # fires; selection focus is only a visual affordance.
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])
    Process.sleep(50)

    # Focus an agent row, not the max chip.
    assert App.snapshot(app).selection_focus == :agents

    App.adjust_max_concurrent_agents(app, 1)
    App.adjust_max_concurrent_agents(app, -1)

    assert_receive {:mock_adjust_max, 1}, 500
    assert_receive {:mock_adjust_max, -1}, 500
  end

  test "activate stays responsive when PaneManager parks the open (F1 regression)", %{app: app} do
    # Regression: AgentList.handle_cast(:activate) used to call
    # PaneManager.open_conversation synchronously inside the cast handler.
    # When PaneManager parked the call (no slot ready during cold pre-warm),
    # the default 5 s GenServer.call timeout crashed the AgentList process,
    # losing every subsequent keystroke. Fix moves the call to Task.start
    # so the cast returns immediately and the input loop stays alive.
    send_running_change(app, [AgentEvents.agent_summary("MT-PARK", :running, 0)])
    Process.sleep(50)

    # Capture the AgentList pid so we can assert it survives.
    app_pid = GenServer.whereis(app)
    assert is_pid(app_pid)
    assert Process.alive?(app_pid)

    # Mock open: receive the open marker, but never reply (simulating a
    # parked call that takes longer than 5 s).
    mark_warm(app, "MT-PARK")
    App.activate(app)
    assert_receive {:mock_open, "MT-PARK", "echo open MT-PARK"}, 500

    # Even though the open is "parked" (the mock GenServer hasn't replied
    # to the Task), AgentList must remain responsive to further casts.
    # Wait past the default 5 s GenServer.call timeout to confirm no crash.
    Process.sleep(5_500)

    assert Process.alive?(app_pid),
           "AgentList must NOT crash when PaneManager parks the open call"
  end

  test "activate uses the visible-row order, not raw input order", %{app: app} do
    # Regression: the renderer filters out terminal-state agents and sorts
    # running-first then by identifier before drawing. If the :activate
    # handler indexes the unfiltered/unsorted list, visual row N opens the
    # wrong agent — observed as "opens the agent 2 rows below" in the wild.
    done = Map.put(AgentEvents.agent_summary("MT-X", :running, 0), :tag, "agent:done")

    send_running_change(app, [
      done,
      AgentEvents.agent_summary("MT-C", :running, 0),
      AgentEvents.agent_summary("MT-B", :queued, 0),
      AgentEvents.agent_summary("MT-A", :running, 0)
    ])

    Process.sleep(50)

    # Visible+sorted order: [MT-A running, MT-C running, MT-B queued].
    # Selection starts at 0 → activate must open MT-A, not the raw[0] (MT-X done).
    mark_warm(app, "MT-A")
    App.activate(app)
    assert_receive {:mock_open, "MT-A", "echo open MT-A"}, 500

    App.select_next(app)
    Process.sleep(20)
    mark_warm(app, "MT-C")
    App.activate(app)
    assert_receive {:mock_open, "MT-C", "echo open MT-C"}, 500

    App.select_next(app)
    Process.sleep(20)
    mark_warm(app, "MT-B")
    App.activate(app)
    assert_receive {:mock_open, "MT-B", "echo open MT-B"}, 500
  end

  describe "deactivated state visibility" do
    test "deactivated summaries stay visible and show 100% progress bar", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-WORK", :running, 0, %{work_state: :working}),
        AgentEvents.agent_summary("DA-DEACT", :running, 0, %{work_state: :deactivated})
      ])

      assert_receive {:rendered, _output}, 500

      snapshot = App.snapshot(app)

      # Both rows visible in summaries (no compaction drop).
      identifiers = Enum.map(snapshot.summaries, & &1.identifier)
      assert "DA-WORK" in identifiers
      assert "DA-DEACT" in identifiers

      # Deactivated rows get 100% progress seeded by seed_deactivated_progress.
      # Working rows with no TicketActivity evidence remain unknown.
      assert [{100, _}] = Map.get(snapshot.progress_by_id, "DA-DEACT", [])
      assert Map.get(snapshot.progress_by_id, "DA-WORK", []) == []
    end

    test "agents_with_content preserved across :working → :deactivated transition", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-CONTENT", :running, 0, %{work_state: :working})
      ])

      assert_receive {:rendered, _}, 500

      # Promote to 'has content' via the chat_active broadcast.
      send(GenServer.whereis(app), {:agent_chat_active, "DA-CONTENT"})

      wait_until(fn ->
        snapshot = App.snapshot(app)
        MapSet.member?(snapshot.agents_with_content, "DA-CONTENT")
      end)

      # Now flip the same id to :deactivated. The ⚪ glyph state
      # (agents_with_content membership) must survive.
      send_running_change(app, [
        AgentEvents.agent_summary("DA-CONTENT", :running, 0, %{work_state: :deactivated})
      ])

      assert_receive {:rendered, _}, 500

      snapshot = App.snapshot(app)
      assert MapSet.member?(snapshot.agents_with_content, "DA-CONTENT")
    end

    test "running map of only :deactivated rows still shows them all", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-1", :running, 0, %{work_state: :deactivated}),
        AgentEvents.agent_summary("DA-2", :running, 0, %{work_state: :deactivated}),
        AgentEvents.agent_summary("DA-3", :running, 0, %{work_state: :deactivated})
      ])

      assert_receive {:rendered, _}, 500

      snapshot = App.snapshot(app)
      identifiers = Enum.map(snapshot.summaries, & &1.identifier)

      assert Enum.sort(identifiers) == ["DA-1", "DA-2", "DA-3"]

      # Deactivated rows always get 100% progress seeded.
      for id <- identifiers do
        assert [{100, _}] = Map.get(snapshot.progress_by_id, id, [])
      end
    end

    test "enter on a :deactivated row routes through Orchestrator.resume_agent", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-ENTER", :running, 0, %{work_state: :deactivated})
      ])

      assert_receive {:rendered, _}, 500

      App.activate(app)

      # Reactivation kicks off in a Task — give it a beat to fire.
      assert_receive {:mock_resume, "DA-ENTER"}, 500
    end
  end

  describe "remote control toggle (r)" do
    test "r on a running agent calls set_remote_control(id, true), then false", %{app: app, orchestrator: orchestrator} do
      send_running_change(app, [AgentEvents.agent_summary("RC-1", :running, 0)])
      assert_receive {:rendered, _}, 500

      App.toggle_remote_control(app)
      assert_receive {:mock_set_remote_control, "RC-1", true}, 500

      # Now simulate the summary coming back RC-on; pressing again toggles off.
      GenServer.cast(orchestrator, {:set_rc_result, {:ok, :off}})
      send_running_change(app, [AgentEvents.agent_summary("RC-1", :running, 0, %{remote_control: %{status: :on}})])
      assert_receive {:rendered, _}, 500

      App.toggle_remote_control(app)
      assert_receive {:mock_set_remote_control, "RC-1", false}, 500
    end

    test "r with no selection surfaces a hint and makes no call", %{app: app} do
      # No running_changed sent — empty summaries, focus is on the max chip.
      assert_receive {:rendered, _}, 500

      App.toggle_remote_control(app)

      refute_receive {:mock_set_remote_control, _, _}, 200

      wait_until(fn -> App.snapshot(app).remote_control_hint != nil end)
      assert App.snapshot(app).remote_control_hint =~ "Remote Control"
    end

    test "an :unsupported result surfaces the local-Claude hint", %{app: app, orchestrator: orchestrator} do
      GenServer.cast(orchestrator, {:set_rc_result, {:error, :unsupported}})
      send_running_change(app, [AgentEvents.agent_summary("RC-CDX", :running, 0)])
      assert_receive {:rendered, _}, 500

      App.toggle_remote_control(app)
      assert_receive {:mock_set_remote_control, "RC-CDX", true}, 500

      wait_until(fn -> App.snapshot(app).remote_control_hint != nil end)
      assert App.snapshot(app).remote_control_hint =~ "requires a local Claude agent"
    end

    test "Space on an RC-on agent does not pause and surfaces a hint", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("RC-ON", :running, 0, %{remote_control: %{status: :on}})
      ])

      assert_receive {:rendered, _}, 500

      App.toggle_pause(app)

      refute_receive {:mock_pause, "RC-ON"}, 200

      wait_until(fn -> App.snapshot(app).remote_control_hint != nil end)
      assert App.snapshot(app).remote_control_hint =~ "Remote Control"
    end

    test "a summary carrying remote_control survives a render cycle (Map.take guard)", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("RC-KEEP", :running, 0, %{remote_control: %{status: :on}})
      ])

      assert_receive {:rendered, _}, 500

      summary = App.snapshot(app).summaries |> Enum.find(&(&1.identifier == "RC-KEEP"))
      assert summary.remote_control == %{status: :on}
    end
  end
end
