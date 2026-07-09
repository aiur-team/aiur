defmodule Aiur.Claude.Repl.ReaperTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})
    %{tmux: name}
  end

  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp respond_error(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%error 1 1 0\n"})
  end

  describe "default_repl_name/0" do
    test "matches aiur-repl-<digits>-<digits>" do
      name = Reaper.default_repl_name()
      assert name =~ ~r/^aiur-repl-\d+-\d+$/
    end
  end

  describe "pane_alive?/1" do
    test "returns true when pane_pid succeeds", %{tmux: tmux} do
      session = %{tmux: tmux, pane_id: "%5"}
      task = Task.async(fn -> Reaper.pane_alive?(session) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %5 \#{pane_pid}"}, 1_000
      respond(tmux, "9999\n")
      assert Task.await(task, 2_000) == true
    end

    test "returns false when pane_pid errors", %{tmux: tmux} do
      session = %{tmux: tmux, pane_id: "%6"}
      task = Task.async(fn -> Reaper.pane_alive?(session) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %6 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")
      assert Task.await(task, 2_000) == false
    end
  end

  describe "stop_session/1" do
    test "unregisters, kills pane, returns :ok for a session map", %{tmux: tmux} do
      # Use a safely-dead pid so graceful_kill_tree is a no-op
      session = %{tmux: tmux, pane_id: "%9", os_pid: 2_147_480_000, workspace: "/ws"}
      task = Task.async(fn -> Reaper.stop_session(session) end)

      assert_receive {:tmux_mock_out, "kill-pane -t %9"}, 1_000
      respond(tmux, "")

      # pane_pid check (gone → error)
      assert_receive {:tmux_mock_out, "display-message -p -t %9 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert Task.await(task, 2_000) == :ok
    end

    test "returns :ok for an invalid session map" do
      assert Reaper.stop_session(%{}) == :ok
      assert Reaper.stop_session(nil) == :ok
    end
  end

  describe "reap_orphaned_panes/1" do
    test "kills only windows with dead-owner pids, returns :ok", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.reap_orphaned_panes(tmux) end)

      assert_receive {:tmux_mock_out, "list-windows -a -F \#{window_name}\t\#{pane_id}"}, 1_000
      # Embed a pid that is certainly dead (very large number)
      respond(tmux, "aiur-repl-2147480001-1\t%20\n")

      assert_receive {:tmux_mock_out, "display-message -p -t %20 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert_receive {:tmux_mock_out, "kill-pane -t %20"}, 1_000
      respond(tmux, "")

      assert Task.await(task, 2_000) == :ok
    end

    test "list-windows error returns :ok and kills nothing", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.reap_orphaned_panes(tmux) end)

      assert_receive {:tmux_mock_out, "list-windows -a -F \#{window_name}\t\#{pane_id}"}, 1_000
      respond_error(tmux, "no server\n")

      assert Task.await(task, 2_000) == :ok
      refute_receive {:tmux_mock_out, "kill-pane" <> _}, 200
    end
  end

  describe "sweep_own_panes/1" do
    test "kills only windows owned by this BEAM, returns :ok", %{tmux: tmux} do
      self_pid = List.to_string(:os.getpid())
      task = Task.async(fn -> Reaper.sweep_own_panes(tmux) end)

      assert_receive {:tmux_mock_out, "list-windows -a -F \#{window_name}\t\#{pane_id}"}, 1_000
      # One window with this BEAM's pid, one with a different pid
      respond(tmux, "aiur-repl-#{self_pid}-1\t%30\naiur-repl-2147480002-1\t%31\n")

      # Only %30 should be killed (owned by this BEAM)
      assert_receive {:tmux_mock_out, "display-message -p -t %30 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert_receive {:tmux_mock_out, "kill-pane -t %30"}, 1_000
      respond(tmux, "")

      assert Task.await(task, 2_000) == :ok
      refute_receive {:tmux_mock_out, "kill-pane -t %31"}, 200
    end
  end
end
