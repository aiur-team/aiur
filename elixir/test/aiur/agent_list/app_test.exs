defmodule Aiur.AgentList.AppTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEvents
  alias Aiur.AgentList.App
  alias Aiur.AgentPubSub

  defmodule MockPaneManager do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def open_conversation(pid, identifier, command) do
      GenServer.call(pid, {:open, identifier, command})
    end

    def handle_call({:open, identifier, command}, _from, parent) do
      send(parent, {:mock_open, identifier, command})
      {:reply, {:ok, "%999"}, parent}
    end
  end

  setup do
    parent = self()
    {:ok, pm} = start_supervised({MockPaneManager, parent})

    name = Module.concat(__MODULE__, :"App#{System.unique_integer([:positive])}")

    write_fun = fn iodata -> send(parent, {:rendered, IO.iodata_to_binary(iodata)}) end

    {:ok, _pid} =
      start_supervised(
        {App,
         [
           name: name,
           write_fun: write_fun,
           pane_manager: pm,
           command_template: "echo open"
         ]},
        id: name
      )

    %{app: name, pm: pm}
  end

  test "renders on startup", %{} do
    assert_receive {:rendered, _output}, 500
  end

  test "running_changed populates summaries and re-renders", %{app: app} do
    AgentPubSub.broadcast_running_change([AgentEvents.agent_summary("MT-A", :running, 0)])
    assert_receive {:rendered, output} when is_binary(output), 500

    assert App.snapshot(app).summaries == [
             %{identifier: "MT-A", status: :running, alert_count: 0}
           ]
  end

  test "select_next and select_previous wrap around", %{app: app} do
    AgentPubSub.broadcast_running_change([
      AgentEvents.agent_summary("MT-A", :running, 0),
      AgentEvents.agent_summary("MT-B", :running, 0)
    ])

    # Drain renders.
    Process.sleep(50)

    App.select_next(app)
    Process.sleep(20)
    assert App.snapshot(app).selection_index == 1

    App.select_next(app)
    Process.sleep(20)
    assert App.snapshot(app).selection_index == 0

    App.select_previous(app)
    Process.sleep(20)
    assert App.snapshot(app).selection_index == 1
  end

  test "activate calls PaneManager with the selected identifier and command", %{app: app} do
    AgentPubSub.broadcast_running_change([AgentEvents.agent_summary("MT-FOCUS", :running, 0)])
    Process.sleep(50)

    App.activate(app)

    assert_receive {:mock_open, "MT-FOCUS", "echo open MT-FOCUS"}, 500
  end

  test "activate uses the visible-row order, not raw input order", %{app: app} do
    # Regression: the renderer filters out terminal-state agents and sorts
    # running-first then by identifier before drawing. If the :activate
    # handler indexes the unfiltered/unsorted list, visual row N opens the
    # wrong agent — observed as "opens the agent 2 rows below" in the wild.
    done = Map.put(AgentEvents.agent_summary("MT-X", :running, 0), :tag, "agent:done")

    AgentPubSub.broadcast_running_change([
      done,
      AgentEvents.agent_summary("MT-C", :running, 0),
      AgentEvents.agent_summary("MT-B", :queued, 0),
      AgentEvents.agent_summary("MT-A", :running, 0)
    ])

    Process.sleep(50)

    # Visible+sorted order: [MT-A running, MT-C running, MT-B queued].
    # Selection starts at 0 → activate must open MT-A, not the raw[0] (MT-X done).
    App.activate(app)
    assert_receive {:mock_open, "MT-A", "echo open MT-A"}, 500

    App.select_next(app)
    Process.sleep(20)
    App.activate(app)
    assert_receive {:mock_open, "MT-C", "echo open MT-C"}, 500

    App.select_next(app)
    Process.sleep(20)
    App.activate(app)
    assert_receive {:mock_open, "MT-B", "echo open MT-B"}, 500
  end
end
