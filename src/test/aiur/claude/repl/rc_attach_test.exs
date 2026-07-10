defmodule Aiur.Claude.Repl.RcAttachTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.Repl.RcAttach
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

  # Drain all capture-pane polls (replying with no URL) until the Esc dismiss fires.
  defp drain_until_esc(tmux, pane) do
    receive do
      {:tmux_mock_out, "capture-pane -p -t " <> ^pane} ->
        respond(tmux, "  Remote Control dialog (no url)\n")
        drain_until_esc(tmux, pane)

      {:tmux_mock_out, "send-keys -t " <> ^pane <> " Escape"} ->
        respond(tmux, "")
    after
      6_000 -> flunk("did not observe Escape within dialog timeout")
    end
  end

  test "banner form: returns URL from the pane text immediately", %{tmux: tmux} do
    task =
      Task.async(fn ->
        RcAttach.capture_session_url(tmux, "%1", [])
      end)

    assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 1_000
    respond(tmux, "/remote-control is active · https://claude.ai/code/session_01Banner\n")

    assert Task.await(task, 2_000) == "https://claude.ai/code/session_01Banner"
  end

  test "footer form: types /rc, Enter, scrapes dialog URL, then sends Esc", %{tmux: tmux} do
    task =
      Task.async(fn ->
        RcAttach.capture_session_url(tmux, "%2", [])
      end)

    # First capture shows /rc active footer but no banner URL
    assert_receive {:tmux_mock_out, "capture-pane -p -t %2"}, 1_000
    respond(tmux, "❯\n  /rc active\n")

    # Send /rc
    assert_receive {:tmux_mock_out, "send-keys -t %2 -l /rc"}, 1_000
    respond(tmux, "")

    # Send Enter
    assert_receive {:tmux_mock_out, "send-keys -t %2 Enter"}, 1_000
    respond(tmux, "")

    # Capture the dialog
    assert_receive {:tmux_mock_out, "capture-pane -p -t %2"}, 1_000
    respond(tmux, "  This session is available at https://claude.ai/code/session_01Footer.\n")

    # Always-dismiss Esc
    assert_receive {:tmux_mock_out, "send-keys -t %2 Escape"}, 1_000
    respond(tmux, "")

    assert Task.await(task, 2_000) == "https://claude.ai/code/session_01Footer"
  end

  test "scrape timeout still sends Esc and returns nil (always-dismiss invariant)", %{tmux: tmux} do
    task =
      Task.async(fn ->
        RcAttach.capture_session_url(tmux, "%3", [])
      end)

    # Shows /rc active footer
    assert_receive {:tmux_mock_out, "capture-pane -p -t %3"}, 1_000
    respond(tmux, "❯\n  /rc active\n")

    # /rc and Enter
    assert_receive {:tmux_mock_out, "send-keys -t %3 -l /rc"}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "send-keys -t %3 Enter"}, 1_000
    respond(tmux, "")

    # Drain all capture-pane dialog polls (no URL) until Esc fires.
    # do_capture_session_url loops until its deadline expires, so there may
    # be multiple polls before the function gives up and sends the dismiss.
    drain_until_esc(tmux, "%3")

    assert Task.await(task, 2_000) == nil
  end

  test "no evidence within budget returns nil", %{tmux: tmux} do
    task =
      Task.async(fn ->
        RcAttach.capture_session_url(tmux, "%4", url_capture_timeout_ms: 0)
      end)

    # Budget is 0ms, so after first capture with no evidence → returns nil immediately
    assert_receive {:tmux_mock_out, "capture-pane -p -t %4"}, 1_000
    respond(tmux, "❯\n")

    assert Task.await(task, 2_000) == nil
  end
end
