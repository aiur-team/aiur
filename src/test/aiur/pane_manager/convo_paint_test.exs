defmodule Aiur.PaneManager.ConvoPaintTest do
  use ExUnit.Case, async: true

  alias Aiur.PaneManager.ConvoPaint
  alias Aiur.Tmux

  setup do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Aiur.Perf.topic())

    %{tmux: tmux_name}
  end

  describe "detect_convo_first_paint/5" do
    test "sends {:convo_first_paint, ...} when tmux pane contains the marker", %{tmux: tmux} do
      pm = self()

      task =
        Task.async(fn ->
          ConvoPaint.detect_convo_first_paint(pm, tmux, "issue-1", 1, "%10")
        end)

      receive do
        {:tmux_mock_out, "capture-pane -p -t %10"} ->
          content = "some text\n  Build · issue-1 · 2.3s\nmore text"
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{content}\n%end 1 1 0\n"})
      after
        500 -> flunk("expected capture-pane command")
      end

      Task.await(task)

      assert_receive {:convo_first_paint, "issue-1", "%10", wall_ms} when is_integer(wall_ms)

      assert_receive {:aiur_perf, %{phase: :convo_first_paint, meta: %{identifier: "issue-1", pane_id: "%10", slot: 1}}}
    end

    test "retries when tmux returns no marker, eventually sends paint on second attempt", %{
      tmux: tmux
    } do
      pm = self()

      task =
        Task.async(fn ->
          ConvoPaint.detect_convo_first_paint(pm, tmux, "issue-2", 2, "%20")
        end)

      # First poll: no marker
      receive do
        {:tmux_mock_out, "capture-pane -p -t %20"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\nLoading...\n%end 1 1 0\n"})
      after
        500 -> flunk("expected first capture-pane")
      end

      # Second poll: marker present
      receive do
        {:tmux_mock_out, "capture-pane -p -t %20"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\nBuild · issue-2 · 1.0s\n%end 1 1 0\n"})
      after
        500 -> flunk("expected second capture-pane")
      end

      Task.await(task, 5000)

      assert_receive {:convo_first_paint, "issue-2", "%20", _wall_ms}

      assert_receive {:aiur_perf, %{phase: :convo_first_paint, meta: %{identifier: "issue-2", pane_id: "%20", slot: 2}}}
    end
  end

  test "pins the poll interval and timeout budget" do
    source = File.read!(Path.expand("../../../lib/aiur/pane_manager/convo_paint.ex", __DIR__))
    assert source =~ "@convo_paint_poll_interval_ms 100"
    assert source =~ "@convo_paint_budget_ms 30_000"
  end
end
