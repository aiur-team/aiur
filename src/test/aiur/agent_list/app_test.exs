defmodule Aiur.AgentList.AppTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEvents
  alias Aiur.AgentList.App

  defmodule MockPaneManager do
    use GenServer

    def start_link(_parent), do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{opens: MapSet.new(), open_waiters: %{}, parked: MapSet.new()}}

    def await_open(pid, identifier, command),
      do: GenServer.call(pid, {:await_open, identifier, command}, :infinity)

    def park_open(pid, identifier), do: GenServer.call(pid, {:park_open, identifier})

    def open_conversation(pid, identifier, command, opts \\ []) do
      GenServer.call(pid, {:open, identifier, command, opts})
    end

    def handle_call({:open, identifier, command, _opts}, _from, state) do
      event = {identifier, command}

      state =
        state.open_waiters
        |> Map.get(event, [])
        |> Enum.reduce(state, fn waiter, state ->
          GenServer.reply(waiter, :ok)
          state
        end)
        |> Map.update!(:opens, &MapSet.put(&1, event))
        |> Map.update!(:open_waiters, &Map.delete(&1, event))

      if MapSet.member?(state.parked, identifier),
        do: {:noreply, state},
        else: {:reply, {:ok, "%999"}, state}
    end

    def handle_call({:await_open, identifier, command}, from, state) do
      event = {identifier, command}

      if MapSet.member?(state.opens, event) do
        {:reply, :ok, state}
      else
        {:noreply, update_in(state.open_waiters[event], fn waiters -> [from | waiters || []] end)}
      end
    end

    def handle_call({:park_open, identifier}, _from, state),
      do: {:reply, :ok, update_in(state.parked, &MapSet.put(&1, identifier))}

    def handle_call({:attach, _identifier, _command, _opts}, _from, state) do
      {:reply, {:error, :no_focused_pane}, state}
    end

    def handle_call(:list, _from, state), do: {:reply, %{}, state}

    def handle_call(:toggle_orientation, _from, state),
      do: {:reply, {:ok, :vertical}, state}
  end

  defmodule MockOrchestrator do
    use GenServer

    def start_link(_parent), do: GenServer.start_link(__MODULE__, :ok)

    def init(:ok),
      do:
        {:ok,
         %{
           max: 2,
           resume_result: {:ok, :resumed},
           adjust_result: nil,
           rc_result: {:ok, :on},
           calls: MapSet.new(),
           call_waiters: %{}
         }}

    def await_call(pid, call), do: GenServer.call(pid, {:await_call, call}, :infinity)
    def calls(pid), do: GenServer.call(pid, :calls)

    def handle_call(:max_concurrent_agents, _from, state) do
      {:reply, %{active: 0, paused: 0, configured: 2, max: state.max, session_override?: true}, state}
    end

    def handle_call({:pause_agent, identifier}, _from, state) do
      {:reply, {:ok, 101}, record_call(state, {:pause, identifier})}
    end

    def handle_call({:resume_agent, identifier}, _from, state) do
      {:reply, state.resume_result, record_call(state, {:resume, identifier})}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, %{adjust_result: nil} = state) do
      next = max(state.max + delta, 1)
      state = state |> record_call({:adjust_max, delta}) |> Map.put(:max, next)
      {:reply, {:ok, %{active: 0, paused: 0, configured: 2, max: next, session_override?: true}}, state}
    end

    def handle_call({:adjust_max_concurrent_agents, delta}, _from, state) do
      {:reply, state.adjust_result, record_call(state, {:adjust_max, delta})}
    end

    def handle_call({:set_remote_control, identifier, on?}, _from, state) do
      {:reply, state.rc_result, record_call(state, {:set_remote_control, identifier, on?})}
    end

    def handle_call({:await_call, call}, from, state) do
      if MapSet.member?(state.calls, call) do
        {:reply, :ok, state}
      else
        {:noreply, update_in(state.call_waiters[call], fn waiters -> [from | waiters || []] end)}
      end
    end

    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    def handle_cast({:set_resume_result, result}, state), do: {:noreply, %{state | resume_result: result}}
    def handle_cast({:set_adjust_result, result}, state), do: {:noreply, %{state | adjust_result: result}}
    def handle_cast({:set_rc_result, result}, state), do: {:noreply, %{state | rc_result: result}}

    defp record_call(state, call) do
      state.call_waiters
      |> Map.get(call, [])
      |> Enum.each(&GenServer.reply(&1, :ok))

      %{state | calls: MapSet.put(state.calls, call), call_waiters: Map.delete(state.call_waiters, call)}
    end
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

  defp send_running_change(app, summaries) do
    send(GenServer.whereis(app), {:running_changed, summaries})
    App.snapshot(app)
  end

  defp flush_rendered do
    receive do
      {:rendered, _} -> flush_rendered()
    after
      0 -> :ok
    end
  end

  defp mark_warm(app, identifier) do
    send(GenServer.whereis(app), {:attach_state_changed, identifier, 1, nil})

    assert %{attach_count: n} = App.snapshot(app).attach_state[identifier]
    assert n > 0
  end

  test "renders on startup", %{} do
    assert_received {:rendered, _output}
  end

  test "running_changed populates summaries and re-renders", %{app: app} do
    flush_rendered()
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])
    assert_received {:rendered, output} when is_binary(output)

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

    assert length(App.snapshot(app).summaries) == 2
    :sys.replace_state(GenServer.whereis(app), &%{&1 | selection_focus: :agents, selection_index: 0})

    # First → last
    App.select_next(app)
    snapshot = App.snapshot(app)
    assert snapshot.selection_index == 1
    assert snapshot.selection_focus == :agents

    # Last → max chip (new behavior; no more silent wrap)
    App.select_next(app)
    assert App.snapshot(app).selection_focus == :max_agents

    # Max chip → first
    App.select_next(app)
    snapshot = App.snapshot(app)
    assert snapshot.selection_focus == :agents
    assert snapshot.selection_index == 0

    # First → max chip (symmetric)
    App.select_previous(app)
    assert App.snapshot(app).selection_focus == :max_agents

    # Max chip → last
    App.select_previous(app)
    snapshot = App.snapshot(app)
    assert snapshot.selection_focus == :agents
    assert snapshot.selection_index == 1
  end

  test "activate calls PaneManager with the selected identifier and command", %{app: app, pm: pm} do
    send_running_change(app, [AgentEvents.agent_summary("MT-FOCUS", :running, 0)])
    mark_warm(app, "MT-FOCUS")

    App.activate(app)

    assert :ok = MockPaneManager.await_open(pm, "MT-FOCUS", "echo open MT-FOCUS")
  end

  test "space pauses the selected active agent", %{app: app, orchestrator: orchestrator} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-FOCUS", :running, 0), :work_state, :working)
    ])

    App.toggle_pause(app)
    App.snapshot(app)

    assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:pause, "MT-FOCUS"})
  end

  test "space resumes the selected paused agent", %{app: app, orchestrator: orchestrator} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    App.toggle_pause(app)
    App.snapshot(app)

    assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:resume, "MT-PAUSED"})
  end

  test "space starts the selected queued agent when capacity is available", %{app: app, orchestrator: orchestrator} do
    send_running_change(app, [AgentEvents.agent_summary("MT-QUEUED", :queued, 0)])

    App.toggle_pause(app)
    App.snapshot(app)

    assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:resume, "MT-QUEUED"})
  end

  test "resume beyond capacity rings bell and highlights max control", %{app: app, orchestrator: orchestrator} do
    GenServer.cast(orchestrator, {:set_resume_result, {:error, :max_concurrent_agents_reached}})
    :sys.get_state(orchestrator)

    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    App.toggle_pause(app)
    snapshot = App.snapshot(app)

    assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:resume, "MT-PAUSED"})
    assert_received {:rendered, "\a"}
    assert snapshot.max_agents_alert?
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
    :sys.get_state(orchestrator)

    send_running_change(app, [AgentEvents.agent_summary("MT-QUEUED", :queued, 0)])

    App.toggle_pause(app)
    snapshot = App.snapshot(app)

    assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:resume, "MT-QUEUED"})
    assert_received {:rendered, "\a"}
    assert snapshot.max_agents_alert?
  end

  test "enter opens a paused agent without resuming it", %{app: app, pm: pm, orchestrator: orchestrator} do
    send_running_change(app, [
      Map.put(AgentEvents.agent_summary("MT-PAUSED", :running, 0), :work_state, :paused)
    ])

    mark_warm(app, "MT-PAUSED")

    App.activate(app)

    assert :ok = MockPaneManager.await_open(pm, "MT-PAUSED", "echo open MT-PAUSED")
    App.snapshot(app)
    refute MapSet.member?(MockOrchestrator.calls(orchestrator), {:resume, "MT-PAUSED"})
  end

  test "moving above the first row focuses the max control", %{app: app} do
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])

    App.select_previous(app)
    assert App.snapshot(app).selection_focus == :max_agents

    App.select_next(app)
    snapshot = App.snapshot(app)
    assert snapshot.selection_focus == :agents
    assert snapshot.selection_index == 0
  end

  test "left and right adjust max control regardless of selection focus", %{app: app, orchestrator: orchestrator} do
    # Regression: the keypress used to be gated on `selection_focus == :max_agents`,
    # so ←/→ was silently swallowed when an agent row was selected. The
    # operator perceived the bump as not taking effect. The cast now always
    # fires; selection focus is only a visual affordance.
    send_running_change(app, [AgentEvents.agent_summary("MT-A", :running, 0)])

    # Focus an agent row, not the max chip.
    assert App.snapshot(app).selection_focus == :agents

    App.adjust_max_concurrent_agents(app, 1)
    App.adjust_max_concurrent_agents(app, -1)
    App.snapshot(app)

    calls = MockOrchestrator.calls(orchestrator)
    assert MapSet.member?(calls, {:adjust_max, 1})
    assert MapSet.member?(calls, {:adjust_max, -1})
  end

  test "activate stays responsive when PaneManager parks the open (F1 regression)", %{app: app, pm: pm} do
    # Regression: AgentList.handle_cast(:activate) used to call
    # PaneManager.open_conversation synchronously inside the cast handler.
    # When PaneManager parked the call (no slot ready during cold pre-warm),
    # the default 5 s GenServer.call timeout crashed the AgentList process,
    # losing every subsequent keystroke. Fix moves the call to Task.start
    # so the cast returns immediately and the input loop stays alive.
    send_running_change(app, [AgentEvents.agent_summary("MT-PARK", :running, 0)])

    # Capture the AgentList pid so we can assert it survives.
    app_pid = GenServer.whereis(app)
    assert is_pid(app_pid)
    assert Process.alive?(app_pid)

    # Park the mock open indefinitely, exactly modeling the cold pre-warm call
    # without making the test itself wait for a wall-clock timeout.
    MockPaneManager.park_open(pm, "MT-PARK")
    mark_warm(app, "MT-PARK")
    App.activate(app)
    assert :ok = MockPaneManager.await_open(pm, "MT-PARK", "echo open MT-PARK")

    # App.snapshot/1 is the barrier: it can reply only if the AgentList process
    # stayed free while the activation Task remains parked in PaneManager.
    assert App.snapshot(app)

    assert Process.alive?(app_pid),
           "AgentList must NOT crash when PaneManager parks the open call"
  end

  test "activate uses the visible-row order, not raw input order", %{app: app, pm: pm} do
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

    # Visible+sorted order: [MT-A running, MT-C running, MT-B queued].
    # Selection starts at 0 → activate must open MT-A, not the raw[0] (MT-X done).
    mark_warm(app, "MT-A")
    App.activate(app)
    assert :ok = MockPaneManager.await_open(pm, "MT-A", "echo open MT-A")

    App.select_next(app)
    App.snapshot(app)
    mark_warm(app, "MT-C")
    App.activate(app)
    assert :ok = MockPaneManager.await_open(pm, "MT-C", "echo open MT-C")

    App.select_next(app)
    App.snapshot(app)
    mark_warm(app, "MT-B")
    App.activate(app)
    assert :ok = MockPaneManager.await_open(pm, "MT-B", "echo open MT-B")
  end

  describe "deactivated state visibility" do
    test "deactivated summaries stay visible without invented progress", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-WORK", :running, 0, %{work_state: :working}),
        AgentEvents.agent_summary("DA-DEACT", :running, 0, %{work_state: :deactivated})
      ])

      snapshot = App.snapshot(app)

      # Both rows visible in summaries (no compaction drop).
      identifiers = Enum.map(snapshot.summaries, & &1.identifier)
      assert "DA-WORK" in identifiers
      assert "DA-DEACT" in identifiers

      # TicketActivity is the sole progress owner; absent shared evidence
      # remains unknown for both lifecycle states.
      assert Map.get(snapshot.progress_by_id, "DA-DEACT", []) == []
      assert Map.get(snapshot.progress_by_id, "DA-WORK", []) == []
    end

    test "agents_with_content preserved across :working → :deactivated transition", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-CONTENT", :running, 0, %{work_state: :working})
      ])

      # Promote to 'has content' via the chat_active broadcast.
      send(GenServer.whereis(app), {:agent_chat_active, "DA-CONTENT"})
      assert MapSet.member?(App.snapshot(app).agents_with_content, "DA-CONTENT")

      # Now flip the same id to :deactivated. The ⚪ glyph state
      # (agents_with_content membership) must survive.
      send_running_change(app, [
        AgentEvents.agent_summary("DA-CONTENT", :running, 0, %{work_state: :deactivated})
      ])

      snapshot = App.snapshot(app)
      assert MapSet.member?(snapshot.agents_with_content, "DA-CONTENT")
    end

    test "running map of only :deactivated rows still shows them all", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-1", :running, 0, %{work_state: :deactivated}),
        AgentEvents.agent_summary("DA-2", :running, 0, %{work_state: :deactivated}),
        AgentEvents.agent_summary("DA-3", :running, 0, %{work_state: :deactivated})
      ])

      snapshot = App.snapshot(app)
      identifiers = Enum.map(snapshot.summaries, & &1.identifier)

      assert Enum.sort(identifiers) == ["DA-1", "DA-2", "DA-3"]

      # Lifecycle completion never manufactures shared activity evidence.
      for id <- identifiers do
        assert Map.get(snapshot.progress_by_id, id, []) == []
      end
    end

    test "enter on a :deactivated row routes through Orchestrator.resume_agent", %{app: app, orchestrator: orchestrator} do
      send_running_change(app, [
        AgentEvents.agent_summary("DA-ENTER", :running, 0, %{work_state: :deactivated})
      ])

      App.activate(app)

      # Reactivation runs in a Task, so the mock call itself is the barrier.
      assert :ok = MockOrchestrator.await_call(orchestrator, {:resume, "DA-ENTER"})
    end
  end

  describe "remote control toggle (r)" do
    test "r on a running agent calls set_remote_control(id, true), then false", %{app: app, orchestrator: orchestrator} do
      send_running_change(app, [AgentEvents.agent_summary("RC-1", :running, 0)])

      App.toggle_remote_control(app)
      App.snapshot(app)
      assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:set_remote_control, "RC-1", true})

      # Now simulate the summary coming back RC-on; pressing again toggles off.
      GenServer.cast(orchestrator, {:set_rc_result, {:ok, :off}})
      :sys.get_state(orchestrator)
      send_running_change(app, [AgentEvents.agent_summary("RC-1", :running, 0, %{remote_control: %{status: :on}})])

      App.toggle_remote_control(app)
      App.snapshot(app)
      assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:set_remote_control, "RC-1", false})
    end

    test "r with no selection surfaces a hint and makes no call", %{app: app, orchestrator: orchestrator} do
      # No running_changed sent — empty summaries, focus is on the max chip.
      App.toggle_remote_control(app)
      snapshot = App.snapshot(app)

      refute Enum.any?(MockOrchestrator.calls(orchestrator), &match?({:set_remote_control, _, _}, &1))
      assert snapshot.remote_control_hint =~ "Remote Control"
    end

    test "an :unsupported result surfaces the local-Claude hint", %{app: app, orchestrator: orchestrator} do
      GenServer.cast(orchestrator, {:set_rc_result, {:error, :unsupported}})
      :sys.get_state(orchestrator)
      send_running_change(app, [AgentEvents.agent_summary("RC-CDX", :running, 0)])

      App.toggle_remote_control(app)
      snapshot = App.snapshot(app)

      assert MapSet.member?(MockOrchestrator.calls(orchestrator), {:set_remote_control, "RC-CDX", true})
      assert snapshot.remote_control_hint =~ "requires a local Claude agent"
    end

    test "Space on an RC-on agent does not pause and surfaces a hint", %{app: app, orchestrator: orchestrator} do
      send_running_change(app, [
        AgentEvents.agent_summary("RC-ON", :running, 0, %{remote_control: %{status: :on}})
      ])

      App.toggle_pause(app)
      snapshot = App.snapshot(app)

      refute MapSet.member?(MockOrchestrator.calls(orchestrator), {:pause, "RC-ON"})
      assert snapshot.remote_control_hint =~ "Remote Control"
    end

    test "a summary carrying remote_control survives a render cycle (Map.take guard)", %{app: app} do
      send_running_change(app, [
        AgentEvents.agent_summary("RC-KEEP", :running, 0, %{remote_control: %{status: :on}})
      ])

      summary = App.snapshot(app).summaries |> Enum.find(&(&1.identifier == "RC-KEEP"))
      assert summary.remote_control == %{status: :on}
    end
  end
end
