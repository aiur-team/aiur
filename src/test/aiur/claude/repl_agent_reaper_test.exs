defmodule Aiur.Claude.ReplAgentReaperTest do
  use ExUnit.Case, async: true

  alias Aiur.Tmux

  alias Aiur.Claude.ReplAgent

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{tmux: name}
  end

  # Respond to one mock tmux call framed like the control-mode wire format.
  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp respond_error(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%error 1 1 0\n"})
  end

  # --------------------------------------------------------- reaper / sweep

  test "reap_orphaned_panes kills only aiur-repl panes whose owner is dead", %{tmux: tmux} do
    dead_owner = "999999999"
    live_owner = List.to_string(:os.getpid())

    task = Task.async(fn -> ReplAgent.reap_orphaned_panes(tmux) end)

    assert_receive {:tmux_mock_out, "list-windows -a -F " <> _}, 1_000

    respond(
      tmux,
      "aiur-repl-#{dead_owner}-1\t%10\naiur-repl-#{live_owner}-2\t%11\nagents\t%12\n"
    )

    # Only the dead-owner REPL pane is reaped: resolve its pid, then kill it.
    assert_receive {:tmux_mock_out, "display-message -p -t %10 \#{pane_pid}"}, 1_000
    respond_error(tmux, "no pane\n")
    assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
    respond(tmux, "")

    # The live-owner REPL pane and the unrelated window are never touched.
    refute_receive {:tmux_mock_out, "kill-pane -t %11"}, 200
    refute_receive {:tmux_mock_out, "kill-pane -t %12"}, 200

    assert :ok = Task.await(task, 2_000)
  end

  test "sweep_own_panes kills only this instance's REPL panes", %{tmux: tmux} do
    self_owner = List.to_string(:os.getpid())
    other_owner = "999999999"

    task = Task.async(fn -> ReplAgent.sweep_own_panes(tmux) end)

    assert_receive {:tmux_mock_out, "list-windows -a -F " <> _}, 1_000

    respond(
      tmux,
      "aiur-repl-#{self_owner}-1\t%20\naiur-repl-#{other_owner}-2\t%21\n"
    )

    assert_receive {:tmux_mock_out, "display-message -p -t %20 \#{pane_pid}"}, 1_000
    respond_error(tmux, "no pane\n")
    assert_receive {:tmux_mock_out, "kill-pane -t %20"}, 1_000
    respond(tmux, "")

    # A side-by-side instance's pane is left alone.
    refute_receive {:tmux_mock_out, "kill-pane -t %21"}, 200

    assert :ok = Task.await(task, 2_000)
  end
end
