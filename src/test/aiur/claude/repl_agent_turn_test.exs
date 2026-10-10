defmodule Aiur.Claude.ReplAgentTurnTest do
  use ExUnit.Case, async: true

  alias Aiur.Tmux

  alias Aiur.Claude.RemoteControl
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

  # --------------------------------------------------------------- run_turn/4

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

  # A user record carrying the workspace cwd — resolve_transcript_path needs
  # at least one cwd-matching record to claim a jsonl as this session's.
  defp user_record(cwd) do
    Jason.encode!(%{
      "type" => "user",
      "cwd" => cwd,
      "timestamp" => "2026-06-08T12:00:00.000Z",
      "message" => %{"role" => "user", "content" => "hello"}
    }) <> "\n"
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

  # Answer the send-keys + Enter + pane-liveness dance for one turn, appending
  # the completion record after the prompt is sent (the tailer reads `from:
  # :end`, so it only sees records written after run_turn started it).
  defp drive_completing_turn(tmux, path, text, task) do
    expect_prompt_submit(tmux)

    File.write!(path, completion_record(text), [:append])

    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    respond(tmux, "4242\n")

    Task.await(task, 2_000)
  end

  # Keep answering pane-liveness polls (pane alive) until the run_turn task
  # finishes — used by the timeout case, which never appends a completion.
  defp drain_pane_pid(tmux, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        drain_pane_pid(tmux, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> drain_pane_pid(tmux, task)
        end
    end
  end

  test "run_turn sends the prompt, streams transcript events, completes on end_turn", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)
    tp = self()

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{},
          on_message: fn m -> send(tp, {:msg, m}) end,
          poll_interval_ms: 10
        )
      end)

    assert {:ok, result} = drive_completing_turn(tmux, path, "All done.", task)
    assert result.result == :completed
    assert is_binary(result.turn_id)
    assert is_binary(result.session_id)

    assert_receive {:msg, %{event: :session_started, turn_id: tid}}, 1000
    assert tid == result.turn_id
    assert_receive {:msg, %{event: :transcript, transcript_event: %{role: :assistant, body: "All done."}}}, 1000
    assert_receive {:msg, %{event: :turn_completed}}, 1000
  end

  # Pump all interleaved mock traffic (pane-liveness polls + the mid-turn
  # inject's send-keys) until the run_turn task finishes. Captures the
  # injected text and writes the completion record only after the inject's
  # Enter, so the turn can't complete before the operator message lands.
  defp pump_mid_turn(tmux, path, task, injected \\ nil) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        pump_mid_turn(tmux, path, task, injected)

      {:tmux_mock_out, "send-keys -t %50 -l " <> text} ->
        respond(tmux, "")
        pump_mid_turn(tmux, path, task, text)

      {:tmux_mock_out, "send-keys -t %50 Enter"} ->
        respond(tmux, "")
        if injected, do: File.write!(path, completion_record("done"), [:append])
        pump_mid_turn(tmux, path, task, injected)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> {result, injected}
          nil -> pump_mid_turn(tmux, path, task, injected)
        end
    end
  end

  test "an operator message landing mid-turn is typed straight into the live pane", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)
    tp = self()

    on_operator = fn ->
      {:deliver_text, "steer left", fn _ -> send(tp, :delivered) end, fn _ -> send(tp, :failed) end}
    end

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "start work", %{},
          on_operator_message: on_operator,
          poll_interval_ms: 10
        )
      end)

    # Prompt is pasted first (before the await loop), deterministically.
    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "[Pasted text +1 lines]\n")
    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")

    # Operator steers mid-turn; the orchestrator's deliver-now broadcast
    # reaches the await loop running in this task's process.
    send(task.pid, {:agent_queue_updated, "MT-1", 1, true})

    assert {result, injected} = pump_mid_turn(tmux, path, task)
    assert injected == "steer left"
    assert_receive :delivered, 1_000
    assert {:ok, %{result: :completed}} = result
  end

  test "a non-deliver-now queue update is ignored mid-turn (no inject)", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)
    tp = self()

    on_operator = fn ->
      send(tp, :claimed)
      :noop
    end

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "work", %{},
          on_operator_message: on_operator,
          poll_interval_ms: 10
        )
      end)

    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "[Pasted text +1 lines]\n")
    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")

    # deliver_now=false (checkpoint-class) and the bare 3-tuple must NOT
    # claim or inject — the REPL only injects on the deliver-now signal.
    send(task.pid, {:agent_queue_updated, "MT-1", 1, false})
    send(task.pid, {:agent_queue_updated, "MT-1", 2})
    refute_receive :claimed, 100

    File.write!(path, completion_record("done"), [:append])
    assert {:ok, %{result: :completed}} = drive_pane_to_completion(tmux, task)
  end

  # Answer only pane-liveness polls until the turn completes (used when no
  # inject is expected, so there are no extra send-keys to drain).
  defp drive_pane_to_completion(tmux, task) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        drive_pane_to_completion(tmux, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> drive_pane_to_completion(tmux, task)
        end
    end
  end

  test "run_turn rejects an empty/whitespace prompt without sending keys", %{tmux: tmux} do
    session = turn_session(tmux, temp_transcript())

    assert {:error, :empty_prompt} = ReplAgent.run_turn(session, "   ", %{}, [])
    refute_receive {:tmux_mock_out, _}, 100
  end

  test "run_turn cold-starts: sends the prompt, awaits the jsonl, then tails it", %{tmux: tmux} do
    # Fresh workspace — claude has not written the session jsonl yet, so the
    # session carries a nil transcript_path and resolve finds nothing.
    ws = Aiur.TestSupport.tmp_root!("repl-cold")
    projects_dir = Aiur.TestSupport.tmp_root!("repl-proj")
    slug_dir = Path.join(projects_dir, RemoteControl.workspace_slug(ws))
    File.mkdir_p!(slug_dir)
    on_exit(fn -> File.rm_rf!(ws) end)
    on_exit(fn -> File.rm_rf!(projects_dir) end)

    session =
      turn_session(tmux, nil)
      |> Map.put(:workspace, ws)
      |> Map.put(:projects_dir, projects_dir)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "hello", %{}, poll_interval_ms: 15)
      end)

    # Cold start sends the prompt BEFORE any transcript exists.
    expect_prompt_submit(tmux)

    # claude now materializes the cwd-matching jsonl with a terminal record.
    path = Path.join(slug_dir, "#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, user_record(ws) <> completion_record("done"))

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.result == :completed
  end

  # Drive a turn whose first keystrokes are dropped: capture-pane reports no
  # echo until a clear_input (C-u) retype lands, after which the prompt echoes
  # and the turn completes.
  defp drive_retype_turn(tmux, path, task, retyped? \\ false) do
    receive do
      {:tmux_mock_out, "load-buffer " <> _} ->
        respond(tmux, "")
        drive_retype_turn(tmux, path, task, retyped?)

      {:tmux_mock_out, "paste-buffer " <> _} ->
        respond(tmux, "")
        drive_retype_turn(tmux, path, task, retyped?)

      {:tmux_mock_out, "send-keys -t " <> rest} ->
        respond(tmux, "")
        drive_retype_turn(tmux, path, task, retyped? or String.contains?(rest, " C-u"))

      {:tmux_mock_out, "capture-pane" <> _} ->
        if retyped?, do: respond(tmux, "❯ retry me\n"), else: respond(tmux, "❯\n")
        drive_retype_turn(tmux, path, task, retyped?)

      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        File.write!(path, completion_record("ok"), [:append])
        drive_retype_turn(tmux, path, task, retyped?)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> drive_retype_turn(tmux, path, task, retyped?)
        end
    end
  end

  test "run_turn re-types after a dropped send and submits once the echo lands", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "retry me", %{},
          poll_interval_ms: 10,
          prompt_confirm_ms: 5_000,
          prompt_retype_ms: 10
        )
      end)

    assert {:ok, result} = drive_retype_turn(tmux, path, task)
    assert result.result == :completed
  end

  # Answer every tmux poll but never echo the prompt, so confirm_typed
  # exhausts its budget.
  defp drain_no_echo(tmux, task) do
    receive do
      {:tmux_mock_out, "load-buffer " <> _} ->
        respond(tmux, "")
        drain_no_echo(tmux, task)

      {:tmux_mock_out, "paste-buffer " <> _} ->
        respond(tmux, "")
        drain_no_echo(tmux, task)

      {:tmux_mock_out, "send-keys -t " <> _} ->
        respond(tmux, "")
        drain_no_echo(tmux, task)

      {:tmux_mock_out, "capture-pane" <> _} ->
        respond(tmux, "❯\n")
        drain_no_echo(tmux, task)

      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        drain_no_echo(tmux, task)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> drain_no_echo(tmux, task)
        end
    end
  end

  test "run_turn fails :prompt_not_delivered when the echo never lands", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "never echoes", %{},
          poll_interval_ms: 10,
          prompt_confirm_ms: 200,
          prompt_retype_ms: 50
        )
      end)

    assert {:error, :prompt_not_delivered} = drain_no_echo(tmux, task)
  end

  test "run_turn returns :turn_timeout when no completion arrives", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "hang forever", %{},
          turn_timeout_ms: 80,
          poll_interval_ms: 15
        )
      end)

    expect_prompt_submit(tmux)

    assert {:error, :turn_timeout} = drain_pane_pid(tmux, task)
  end

  test "run_turn surfaces :repl_gone when the pane dies mid-turn", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "work", %{}, poll_interval_ms: 10)
      end)

    expect_prompt_submit(tmux)

    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    respond_error(tmux, "can't find pane\n")

    assert {:error, :repl_gone} = Task.await(task, 2_000)
  end

  test "two sequential run_turns reuse one session (no respawn)", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)
    session = turn_session(tmux, path)

    t1 = Task.async(fn -> ReplAgent.run_turn(session, "first", %{}, poll_interval_ms: 10) end)
    assert {:ok, r1} = drive_completing_turn(tmux, path, "one", t1)

    t2 = Task.async(fn -> ReplAgent.run_turn(session, "second", %{}, poll_interval_ms: 10) end)
    assert {:ok, r2} = drive_completing_turn(tmux, path, "two", t2)

    assert r1.thread_id == r2.thread_id
    assert r1.turn_id != r2.turn_id
    refute_receive {:tmux_mock_out, "new-window" <> _}, 100
  end
end
