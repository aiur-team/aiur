defmodule Aiur.AgentList.ActivationTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Activation

  defmodule PaneManager do
    use GenServer
    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:open, id, command, _opts}, _from, parent) do
      send(parent, {:opened, id, command})
      {:reply, {:ok, "%1"}, parent}
    end

    def handle_call({:attach, _id, _command, _opts}, _from, parent), do: {:reply, {:error, :no_focused_pane}, parent}
  end

  test "uses the opencode sentinel default" do
    assert Activation.default_command_template() == "__aiur_opencode__"
  end

  test "opens a warm selected agent asynchronously" do
    {:ok, pane_manager} = PaneManager.start_link(self())

    state = %{
      summaries: [%{identifier: "A", title: "Title"}],
      selection_index: 0,
      command_template: "echo open",
      pane_manager: pane_manager,
      attach_state: %{"A" => %{attach_count: 1}},
      opened_panes: MapSet.new(),
      progress_by_id: %{}
    }

    assert :ok = Activation.activate_selected(state, :new_pane)
    assert_receive {:opened, "A", "echo open A"}
  end

  test "does not open a completed agent even when stale warmth remains" do
    {:ok, pane_manager} = PaneManager.start_link(self())

    state = %{
      summaries: [%{identifier: "A", title: "Title", work_state: :completed}],
      selection_index: 0,
      command_template: "echo open",
      pane_manager: pane_manager,
      attach_state: %{"A" => %{attach_count: 1}},
      opened_panes: MapSet.new(),
      progress_by_id: %{}
    }

    assert :ok = Activation.activate_selected(state, :new_pane)
    refute_receive {:opened, "A", _command}, 100
  end

  test "opens a deactivated row even when seed_deactivated_progress has forced 100% progress" do
    # seed_deactivated_progress sets progress_by_id to [{100, _}] for all
    # deactivated summaries. Without the deactivated?-before-completed? cond
    # order, completed?(state, summary) returns true for every deactivated row
    # and the deactivated branch is unreachable — Enter silently does nothing.
    {:ok, pane_manager} = PaneManager.start_link(self())

    state = %{
      summaries: [%{identifier: "A", title: "Title", work_state: :deactivated}],
      selection_index: 0,
      command_template: "echo open",
      pane_manager: pane_manager,
      attach_state: %{"A" => %{attach_count: 1}},
      opened_panes: MapSet.new(),
      progress_by_id: %{"A" => [{100, System.monotonic_time(:millisecond)}]}
    }

    assert :ok = Activation.activate_selected(state, :new_pane)
    assert_receive {:opened, "A", "echo open A"}
  end

  test "does not open a 100% row when its roster work state is stale" do
    {:ok, pane_manager} = PaneManager.start_link(self())

    state = %{
      summaries: [%{identifier: "A", title: "Title", work_state: :working}],
      selection_index: 0,
      command_template: "echo open",
      pane_manager: pane_manager,
      attach_state: %{"A" => %{attach_count: 1}},
      opened_panes: MapSet.new(),
      progress_by_id: %{"A" => [{100, 123}]}
    }

    assert :ok = Activation.activate_selected(state, :new_pane)
    refute_receive {:opened, "A", _command}, 100
  end
end
