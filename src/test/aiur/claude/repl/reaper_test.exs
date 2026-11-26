defmodule Aiur.Claude.Repl.ReaperTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.Repl.Reaper
  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")
    {:ok, _pid} = start_supervised({Tmux, [transport: {:mock, test_pid, :infinity}, name: name, session: "test"]})
    %{tmux: name}
  end

  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp respond_error(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%error 1 1 0\n"})
  end

  # Keep this fixture aligned with every host operation exposed by Reaper.
  # A newly added seam must be supplied here before stop_session tests can
  # accidentally touch the host process table.
  defp stop_session(session, overrides \\ []) do
    seam_opts = [
      group_alive_fun: fn _group -> false end,
      group_cleanup_fun: fn _group, _identity, _pane_proven? -> {:ok, :gone} end,
      tree_kill_fun: fn _pid -> :ok end,
      pid_alive_fun: fn _pid -> false end,
      unregister_fun: fn _ref -> :ok end
    ]

    expected_seams = Reaper.host_seam_opts() |> Enum.sort()
    supplied_seams = Keyword.keys(seam_opts) |> Enum.sort()
    if expected_seams != supplied_seams, do: raise("update stop_session fixture for new Reaper host seams")

    Reaper.stop_session(session, Keyword.merge(seam_opts, overrides))
  end

  test "stop_session tests route through the host-seam fixture" do
    source = File.read!(__ENV__.file)

    assert length(Regex.scan(~r/\bReaper\.stop_session\(/, source)) == 1
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

  describe "pane_liveness/1" do
    test "classifies a successful pid reply as alive", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.pane_liveness(%{tmux: tmux, pane_id: "%40"}) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %40 " <> _}, 1_000
      respond(tmux, "9999\n")
      assert Task.await(task, 2_000) == :alive
    end

    test "classifies an explicit missing-pane response as gone", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.pane_liveness(%{tmux: tmux, pane_id: "%41"}) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %41 " <> _}, 1_000
      respond_error(tmux, "can't find pane: %41\n")
      assert Task.await(task, 2_000) == :gone
    end

    test "classifies a stopped tmux server as gone", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.pane_liveness(%{tmux: tmux, pane_id: "%43"}) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %43 " <> _}, 1_000
      respond_error(tmux, "no server running on /tmp/tmux-test/default\n")
      assert Task.await(task, 2_000) == :gone
    end

    test "classifies a tmux timeout as unknown", %{tmux: tmux} do
      task = Task.async(fn -> Reaper.pane_liveness(%{tmux: tmux, pane_id: "%42"}, 0) end)
      assert_receive {:tmux_mock_out, "display-message -p -t %42 " <> _}, 1_000
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n"})
      assert Task.await(task, 2_000) == :unknown
    end
  end

  describe "stop_session/1" do
    test "proves cleanup only after the pane's whole process group is gone", %{tmux: tmux} do
      parent = self()
      {:ok, group_alive} = Agent.start_link(fn -> true end)

      on_exit(fn -> Aiur.TestSupport.safe_stop(group_alive) end)

      session = %{
        tmux: tmux,
        pane_id: "%8",
        os_pid: 2_147_480_000,
        process_group_id: 2_147_480_000,
        process_group_identity: {:known, :original},
        workspace: "/ws"
      }

      task =
        Task.async(fn ->
          stop_session(session,
            group_cleanup_fun: fn group, identity, pane_proven? ->
              send(parent, {:group_cleanup, group, identity, pane_proven?})
              Agent.update(group_alive, fn _ -> false end)
              {:ok, :reaped}
            end,
            group_alive_fun: fn _group -> Agent.get(group_alive, & &1) end
          )
        end)

      assert_receive {:tmux_mock_out, "display-message -p -t %8 \#{pane_pid}"}, 1_000
      respond(tmux, "2147480000\n")
      assert_receive {:group_cleanup, 2_147_480_000, {:known, :original}, true}, 1_000

      assert_receive {:tmux_mock_out, "kill-pane -t %8"}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "display-message -p -t %8 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert {:ok, :cleanup_proven} = Task.await(task, 2_000)
    end

    test "unregisters, kills pane, and proves cleanup for a contained session", %{tmux: tmux} do
      # Use a safely-dead pid so graceful_kill_tree is a no-op
      session = %{
        tmux: tmux,
        pane_id: "%9",
        os_pid: 2_147_480_000,
        process_group_id: 2_147_480_000,
        workspace: "/ws"
      }

      parent = self()

      task =
        Task.async(fn ->
          stop_session(session,
            unregister_fun: fn ref ->
              send(parent, {:unregistered, ref})
              :ok
            end
          )
        end)

      assert_receive {:tmux_mock_out, "display-message -p -t %9 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")
      assert_receive {:tmux_mock_out, "kill-pane -t %9"}, 1_000
      respond(tmux, "")

      # pane_pid check (gone → error)
      assert_receive {:tmux_mock_out, "display-message -p -t %9 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert Task.await(task, 2_000) == {:ok, :cleanup_proven}
      assert_receive {:unregistered, {:pane, "%9"}}, 1_000
      assert_receive {:unregistered, {:os_pid, 2_147_480_000}}, 1_000
    end

    test "trusts observed absence when the group signal races with process exit", %{tmux: tmux} do
      {:ok, group_probes} = Agent.start_link(fn -> [true, false] end)
      on_exit(fn -> Aiur.TestSupport.safe_stop(group_probes) end)

      session = %{
        tmux: tmux,
        pane_id: "%11",
        os_pid: 2_147_480_000,
        process_group_id: 2_147_480_000,
        process_group_identity: {:known, :original},
        workspace: "/ws"
      }

      task =
        Task.async(fn ->
          stop_session(session,
            group_alive_fun: fn _group ->
              Agent.get_and_update(group_probes, fn [result | rest] -> {result, rest} end)
            end,
            group_cleanup_fun: fn _group, _identity, _pane_proven? ->
              {:error, :signal_raced_with_exit}
            end
          )
        end)

      assert_receive {:tmux_mock_out, "display-message -p -t %11 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")
      assert_receive {:tmux_mock_out, "kill-pane -t %11"}, 1_000
      respond_error(tmux, "no pane\n")
      assert_receive {:tmux_mock_out, "display-message -p -t %11 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert Task.await(task, 2_000) == {:ok, :cleanup_proven}
    end

    test "returns :ok for an invalid session map" do
      assert stop_session(%{}) == :ok
      assert stop_session(nil) == :ok
    end

    test "reports cleanup unknown when tmux refuses the pane kill", %{tmux: tmux} do
      session = %{tmux: tmux, pane_id: "%10", os_pid: nil, workspace: "/ws"}
      task = Task.async(fn -> stop_session(session) end)

      assert_receive {:tmux_mock_out, "display-message -p -t %10 \#{pane_pid}"}, 1_000
      respond(tmux, "5050\n")
      assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
      respond_error(tmux, "permission denied\n")

      assert_receive {:tmux_mock_out, "display-message -p -t %10 \#{pane_pid}"}, 1_000
      respond(tmux, "5050\n")

      assert {:error, {:repl_cleanup_failed, :pane_still_alive}} =
               Task.await(task, 2_000)
    end

    test "reports cleanup unknown while the process group remains alive", %{tmux: tmux} do
      process_group_id = 2_147_480_000

      session = %{
        tmux: tmux,
        pane_id: "%12",
        os_pid: process_group_id,
        process_group_id: process_group_id,
        process_group_identity: {:known, :original},
        workspace: "/ws"
      }

      task =
        Task.async(fn ->
          stop_session(session,
            group_alive_fun: fn ^process_group_id -> true end,
            group_cleanup_fun: fn ^process_group_id, {:known, :original}, false ->
              {:error, :signal_refused}
            end
          )
        end)

      assert_receive {:tmux_mock_out, "display-message -p -t %12 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")
      assert_receive {:tmux_mock_out, "kill-pane -t %12"}, 1_000
      respond(tmux, "")
      assert_receive {:tmux_mock_out, "display-message -p -t %12 \#{pane_pid}"}, 1_000
      respond_error(tmux, "no pane\n")

      assert {:error, {:repl_cleanup_failed, :process_group_still_alive}} =
               Task.await(task, 2_000)
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
