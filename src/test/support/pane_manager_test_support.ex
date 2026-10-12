defmodule Aiur.PaneManagerTestSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised: 2]

  alias Aiur.{PaneManager, Tmux}

  def start_pane_manager(max_vertical_panes) do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")
    pm_name = Module.concat(__MODULE__, :"PM#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    {:ok, pid} =
      start_supervised(
        {PaneManager,
         [
           tmux: tmux_name,
           name: pm_name,
           agent_list_pane: "%1",
           window_target: "test:0",
           max_vertical_panes: max_vertical_panes,
           # Pin slot_count to the grid formula so round-robin tests
           # see the expected wrap behavior independent of any
           # max_concurrent_agents value from the runtime workflow.
           slot_count: max_vertical_panes * 2 - 1
         ]},
        id: pm_name
      )

    %{server: pid, tmux: tmux_name, pm: pm_name}
  end

  # The new layout-string flow makes the split anchor and percent
  # irrelevant for positioning, so PaneManager always splits the
  # agent-list pane with a default 50/50 horizontal. Tests assert the
  # invariant rather than per-slot recipes.
  def respond_split(tmux, new_pane_id) do
    receive do
      {:tmux_mock_out, "split-window " <> _ = cmd} ->
        respond_to_split_command(tmux, cmd, new_pane_id)
    after
      1_000 -> flunk("expected split-window")
    end
  end

  def respond_to_split_command(tmux, cmd, new_pane_id) do
    assert cmd =~ "-t %1", "expected split anchored on agent-list pane, got #{inspect(cmd)}"
    assert cmd =~ ~r/(^|\s)-h(\s|$)/, "expected -h, got #{inspect(cmd)}"
    assert cmd =~ ~r/(^|\s)-l 50%(\s|$)/, "expected -l 50%, got #{inspect(cmd)}"

    send(
      GenServer.whereis(tmux),
      {:tmux_mock_data, "%begin 1 1 0\n#{new_pane_id}\n%end 1 1 0\n"}
    )
  end

  def drain_reconcile_if_requested(tmux, live_panes) do
    receive do
      {:tmux_mock_out, "list-panes -t test:0 -F \#{pane_id}"} ->
        body = Enum.join(live_panes, "\n")
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}\n%end 1 1 0\n"})
    after
      20 -> :ok
    end
  end

  def drain_focus(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "select-pane -t " <> rest} ->
        assert String.trim(rest) == pane_id

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 2 0\n%end 1 2 0\n"})
    after
      1_000 -> flunk("expected select-pane focus on #{pane_id}")
    end
  end

  # Every bind (open / respawn / placeholder) sets the pane's tmux title to
  # "<id> <title>" via `select-pane -t <pane> -T ...`. Tests with no `:title`
  # option just see the bare identifier. Drain it so the mock Tmux GenServer
  # isn't left blocked mid-sequence.
  def drain_set_title(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "select-pane -t " <> rest = cmd} ->
        assert rest =~ "-T ", "expected pane-title set, got #{inspect(cmd)}"
        assert rest =~ pane_id, "expected title set on #{pane_id}, got #{inspect(cmd)}"

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 7 0\n%end 1 7 0\n"})
    after
      1_000 -> flunk("expected select-pane -T title set for #{pane_id}")
    end
  end

  def respond_respawn(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "respawn-pane " <> rest} ->
        assert rest =~ "-k"
        assert rest =~ "-t #{pane_id}"

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 3 0\n%end 1 3 0\n"})
    after
      1_000 -> flunk("expected respawn-pane for #{pane_id}")
    end
  end

  # After every open, respawn, and close, PaneManager queries window
  # dimensions and applies a layout string. Tests just drain those —
  # the layout-string content is verified in
  # Aiur.PaneManager.LayoutTest, not here.
  def drain_layout_apply(tmux) do
    receive do
      {:tmux_mock_out, "display-message -p -t %1 " <> _} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 5 0\n80x24\n%end 1 5 0\n"})
    after
      1_000 -> flunk("expected window_size display-message")
    end

    receive do
      {:tmux_mock_out, "select-layout -t test:0 " <> layout} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 6 0\n%end 1 6 0\n"})
        "select-layout -t test:0 " <> layout
    after
      1_000 -> flunk("expected select-layout")
    end
  end

  def open_in_slot(pm, tmux, identifier, new_pane_id) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "echo " <> identifier) end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_split(tmux, new_pane_id)
    drain_focus(tmux, new_pane_id)
    drain_set_title(tmux, new_pane_id)
    drain_layout_apply(tmux)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
  end

  def open_via_respawn(pm, tmux, identifier, pane_id) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "echo " <> identifier) end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_respawn(tmux, pane_id)
    drain_set_title(tmux, pane_id)
    drain_layout_apply(tmux)
    assert {:ok, ^pane_id} = Task.await(task, 1_000)
  end

  def open_in_slot_with_title(pm, tmux, identifier, new_pane_id, title) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]

    task =
      Task.async(fn ->
        PaneManager.open_conversation(pm, identifier, "echo " <> identifier, title: title)
      end)

    drain_reconcile_if_requested(tmux, live_panes)
    respond_split(tmux, new_pane_id)
    drain_focus(tmux, new_pane_id)
    drain_set_title(tmux, new_pane_id)
    drain_layout_apply(tmux)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
  end

  # Like open_via_respawn but passes a :title and returns the exact
  # `select-pane -T` command so a swap test can assert the new agent's title.
  def open_via_respawn_with_title(pm, tmux, identifier, pane_id, title) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]

    task =
      Task.async(fn ->
        PaneManager.open_conversation(pm, identifier, "echo " <> identifier, title: title)
      end)

    drain_reconcile_if_requested(tmux, live_panes)
    respond_respawn(tmux, pane_id)

    title_cmd =
      receive do
        {:tmux_mock_out, "select-pane -t " <> _ = cmd} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 7 0\n%end 1 7 0\n"})
          cmd
      after
        1_000 -> flunk("expected select-pane -T title set for #{pane_id}")
      end

    drain_layout_apply(tmux)
    assert {:ok, ^pane_id} = Task.await(task, 1_000)
    title_cmd
  end

  def open_placeholder(pm, tmux, identifier, new_pane_id, live_panes) do
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "__aiur_opencode__ #{identifier}") end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_split(tmux, new_pane_id)
    drain_focus(tmux, new_pane_id)
    drain_set_title(tmux, new_pane_id)
    layout_cmd = drain_layout_apply(tmux)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
    layout_cmd
  end
end
