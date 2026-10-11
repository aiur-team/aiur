defmodule Aiur.Claude.ReplAgentControlTest do
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

  defp turn_session(tmux, transcript_path, pane \\ "%50") do
    %{
      backend: "claude-repl",
      pane_id: pane,
      os_pid: 4242,
      workspace: System.tmp_dir!(),
      transcript_path: transcript_path,
      model: nil,
      remote_control: false,
      rc_name: "x",
      tmux: tmux
    }
  end

  defp temp_transcript do
    path = Aiur.TestSupport.tmp_root!("repl-turn") <> ".jsonl"
    File.write!(path, "")
    path
  end

  # An assistant record whose `stop_reason` is terminal — the tailer reads
  # this as the turn-completion signal.
  defp completion_record(text) do
    Jason.encode!(%{
      "type" => "assistant",
      "timestamp" => "2026-06-08T12:00:00.000Z",
      "message" => %{
        "role" => "assistant",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => text}]
      }
    }) <> "\n"
  end

  # Consume one prompt submission: paste (load-buffer + paste-buffer),
  # buffer-landed capture-pane (answered with a `[Pasted text]` chip so the
  # check passes), then Enter.
  defp expect_prompt_submit(tmux) do
    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")

    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "[Pasted text +5 lines]\n")

    assert_receive {:tmux_mock_out, "send-keys -t " <> rest2}, 1_000
    assert String.ends_with?(rest2, "Enter")
    respond(tmux, "")
    :ok
  end

  # ----------------------------------------------------- send_operator_message/2

  test "send_operator_message types the text and submits with one Enter", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())

    task = Task.async(fn -> ReplAgent.send_operator_message(session, %{kind: :text, body: "try this"}) end)

    assert_receive {:tmux_mock_out, "send-keys -t %50 -l try this"}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")

    assert {:ok, request_id} = Task.await(task, 2_000)
    assert is_integer(request_id)
  end

  # The text is typed into a live PTY, so control bytes are collapsed to
  # spaces: an embedded newline must NOT submit early, and Esc/control
  # codes must NOT reach the REPL as keybindings. The single trailing
  # Enter is the only submit.
  test "send_operator_message neutralizes a hostile control-char payload", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())
    hostile = "rm -rf\nyes\e[2J\tand more\r\ndrop table"

    task = Task.async(fn -> ReplAgent.send_operator_message(session, %{kind: :text, body: hostile}) end)

    assert_receive {:tmux_mock_out, "send-keys -t %50 -l " <> typed}, 1_000
    respond(tmux, "")
    # No raw control bytes survived, and it is one line (no embedded Enter).
    refute typed =~ ~r/[\x00-\x1f\x7f]/
    assert typed == "rm -rf yes [2J and more drop table"
    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")

    assert {:ok, _} = Task.await(task, 2_000)
    # Exactly one submit — the explicit Enter, not one per embedded newline.
    refute_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 100
  end

  test "send_operator_message rejects a blank message without sending keys", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())

    assert {:error, :empty_message} = ReplAgent.send_operator_message(session, %{kind: :text, body: "  \n\t "})
    refute_receive {:tmux_mock_out, _}, 100
  end

  test "send_operator_message rejects a non-text payload", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())

    assert {:error, :invalid_message} = ReplAgent.send_operator_message(session, %{kind: :image})
    refute_receive {:tmux_mock_out, _}, 100
  end

  # ------------------------------------------------------------- pause mid-turn

  # Pump pane-liveness polls and the pause's C-c interrupt. When the C-c
  # lands, append a completion record so the tailer sees the interrupted
  # turn close (mirrors claude ending the turn after a Ctrl+C).
  defp pump_pause(tmux, path, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        pump_pause(tmux, path, task)

      {:tmux_mock_out, "send-keys -t %50 C-c"} ->
        respond(tmux, "")
        File.write!(path, completion_record("interrupted"), [:append])
        pump_pause(tmux, path, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> pump_pause(tmux, path, task)
        end
    end
  end

  test "a pause request mid-turn interrupts the REPL and returns {:paused, …}", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "long work", %{}, poll_interval_ms: 10)
      end)

    expect_prompt_submit(tmux)

    send(task.pid, {:pause_agent, 42})

    assert {:paused, payload} = pump_pause(tmux, path, task)
    assert payload.request_id == 42
    assert is_binary(payload.session_id)
    assert is_binary(payload.turn_id)
  end

  # Never append a record after the C-c: without terminal evidence, the turn
  # must not report a confirmed pause.
  defp pump_pause_no_turn_end(tmux, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        pump_pause_no_turn_end(tmux, task)

      {:tmux_mock_out, "send-keys -t %50 C-c"} ->
        respond(tmux, "")
        pump_pause_no_turn_end(tmux, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> pump_pause_no_turn_end(tmux, task)
        end
    end
  end

  test "pause-confirm deadline expiry returns an unconfirmed-pause error", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "long work", %{},
          poll_interval_ms: 10,
          pause_confirm_ms: 80
        )
      end)

    expect_prompt_submit(tmux)

    send(task.pid, {:pause_agent, 7})

    assert {:error, :pause_confirmation_timeout} = pump_pause_no_turn_end(tmux, task)
  end

  # A failed C-c (tmux error) is not evidence that the REPL stopped.
  defp pump_pause_interrupt_fails(tmux, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        pump_pause_interrupt_fails(tmux, task)

      {:tmux_mock_out, "send-keys -t %50 C-c"} ->
        respond_error(tmux, "no such pane\n")
        pump_pause_interrupt_fails(tmux, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> pump_pause_interrupt_fails(tmux, task)
        end
    end
  end

  test "a failed interrupt send returns an unconfirmed-pause error", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "long work", %{},
          poll_interval_ms: 10,
          pause_confirm_ms: 80
        )
      end)

    expect_prompt_submit(tmux)

    send(task.pid, {:pause_agent, 9})

    assert {:error, {:pause_interrupt_failed, _reason}} = pump_pause_interrupt_fails(tmux, task)
  end

  # ----------------------------------------------------------------- interrupt/1

  test "interrupt sends Ctrl+C to the pane", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())

    task = Task.async(fn -> ReplAgent.interrupt(session) end)

    assert_receive {:tmux_mock_out, "send-keys -t %50 C-c"}, 1_000
    respond(tmux, "")

    assert :ok = Task.await(task, 2_000)
  end

  test "interrupt rejects a session without a pane" do
    assert {:error, :invalid_session} = ReplAgent.interrupt(%{})
  end
end
