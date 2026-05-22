defmodule Aiur.Regression.AgentListSortTest do
  @moduledoc """
  Regression for "agent list sort puts 10 before 5 because identifiers
  are sorted as strings, not integers" (perf redesign, 2026-05-21).

  Expected order: group by live work state, then by numeric identifier
  ASCENDING within each group.

  Drives the private `visible_summaries/1` through the live App
  GenServer so we exercise the actual transform the renderer reads
  from state.summaries.
  """

  use ExUnit.Case, async: false

  alias Aiur.AgentEvents
  alias Aiur.AgentList.App

  defmodule MockPaneManager do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}
    def handle_call(:list, _from, parent), do: {:reply, %{}, parent}
    def handle_call(_, _from, parent), do: {:reply, :ok, parent}
  end

  defmodule MockOrchestrator do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call(:max_concurrent_agents, _from, parent),
      do: {:reply, %{active: 0, paused: 0, configured: 10, max: 10, session_override?: false}, parent}

    def handle_call(_, _from, parent), do: {:reply, :ok, parent}
  end

  setup do
    {:ok, pm} = MockPaneManager.start_link(self())
    {:ok, orch} = MockOrchestrator.start_link(self())

    app_opts = [
      name: nil,
      pane_manager: pm,
      orchestrator: orch,
      subscribe?: false,
      write_fun: fn _ -> :ok end,
      command_template: "echo open"
    ]

    {:ok, app} = App.start_link(app_opts)
    on_exit(fn -> if Process.alive?(app), do: GenServer.stop(app) end)
    %{app: app}
  end

  test "running agents sort by numeric identifier ascending, not lex order", %{app: app} do
    summaries =
      Enum.map(["5", "9", "10", "11", "13", "20"], fn id ->
        AgentEvents.agent_summary(id, :running, 0)
        |> Map.put(:work_state, :working)
      end)

    send(app, {:running_changed, summaries})
    Process.sleep(50)

    state = :sys.get_state(app)
    ids = Enum.map(state.summaries, & &1.identifier)

    assert ids == ["5", "9", "10", "11", "13", "20"],
           """
           Expected ascending numeric order ["5", "9", "10", "11", "13", "20"]
           but got #{inspect(ids)}.

           If you got ["10", "11", "13", "20", "5", "9"], the sort
           is using string comparison instead of integer.
           """
  end

  test "groups by status emoji bucket before sorting by id within each group", %{app: app} do
    working = fn id ->
      AgentEvents.agent_summary(id, :running, 0)
      |> Map.put(:work_state, :working)
    end

    paused = fn id ->
      AgentEvents.agent_summary(id, :running, 0)
      |> Map.put(:work_state, :paused)
    end

    queued = fn id -> AgentEvents.agent_summary(id, :queued, 0) end

    # Interleaved input — sort MUST regroup.
    summaries = [
      queued.("3"),
      working.("10"),
      paused.("5"),
      working.("2"),
      queued.("1"),
      paused.("8")
    ]

    send(app, {:running_changed, summaries})
    Process.sleep(50)

    state = :sys.get_state(app)
    ids = Enum.map(state.summaries, & &1.identifier)

    # Working first by id asc, then paused by id asc, then queued by id asc.
    assert ids == ["2", "10", "5", "8", "1", "3"],
           """
           Expected work-state groups, each sorted ascending by numeric id:
             [working 2, 10] then [paused 5, 8] then [queued 1, 3]
             == ["2", "10", "5", "8", "1", "3"]
           Got: #{inspect(ids)}
           """
  end
end
