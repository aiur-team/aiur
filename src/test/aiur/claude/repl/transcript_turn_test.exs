defmodule Aiur.Claude.Repl.TranscriptTurnTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.Repl.TranscriptTurn
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

  defp turn_session(tmux, transcript_path, projects_dir \\ nil) do
    ws = System.tmp_dir!()

    %{
      backend: "claude-repl",
      pane_id: "%50",
      os_pid: 4242,
      workspace: ws,
      transcript_path: transcript_path,
      projects_dir: projects_dir,
      started_at: 0,
      model: nil,
      remote_control: false,
      rc_name: "x",
      tmux: tmux
    }
  end

  defp temp_transcript do
    path = Path.join(System.tmp_dir!(), "tt-#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, "")
    path
  end

  defp completion_record(text \\ "done") do
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

  defp api_error_record(status \\ 429, type \\ "rate_limit_error") do
    Jason.encode!(%{
      "type" => "system",
      "subtype" => "api_error",
      "error" => %{"status" => status, "type" => type, "message" => "API request failed"}
    }) <> "\n"
  end

  # Drive pane-pid polls until task finishes.
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

  # Handle all mock traffic until the C-c interrupt fires, then optionally append completion.
  defp pump_until_pause(tmux, task, path \\ nil) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        pump_until_pause(tmux, task, path)

      {:tmux_mock_out, "send-keys -t %50 C-c"} ->
        respond(tmux, "")
        if path, do: File.write!(path, completion_record(), [:append])
        pump_until_pause(tmux, task, path)
    after
      30 ->
        case Task.yield(task, 0) do
          {:ok, result} -> result
          nil -> pump_until_pause(tmux, task, path)
        end
    end
  end

  # Drain paste submission (confirm_typed path: clear + paste + echo + enter).
  defp expect_prompt_submit(tmux) do
    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "[Pasted text +5 lines]\n")
    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")
  end

  test "cold start where the jsonl never materializes returns {:error, :no_transcript}", %{tmux: tmux} do
    # Fresh workspace — no transcript file will ever appear.
    ws = Path.join(System.tmp_dir!(), "tt-cold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    session = %{turn_session(tmux, nil) | workspace: ws, transcript_path: nil, started_at: 0}

    task =
      Task.async(fn ->
        TranscriptTurn.run(session, "hello", poll_interval_ms: 10, turn_timeout_ms: 5_000)
      end)

    # Cold start: sends prompt first (PromptSubmit.send path: paste + echo + enter)
    expect_prompt_submit(tmux)

    # Transcript never materializes → :no_transcript
    assert {:error, :no_transcript} = Task.await(task, 20_000)
  end

  test "warm turn tails from :end and completes with {:ok, completed result}", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)

    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        TranscriptTurn.run(session, "do work", poll_interval_ms: 10)
      end)

    # Warm turn: tailer attaches first, then prompt is submitted
    expect_prompt_submit(tmux)

    File.write!(path, completion_record(), [:append])

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.result == :completed
    assert is_binary(result.session_id)
    assert is_binary(result.thread_id)
    assert is_binary(result.turn_id)
  end

  test "API-error transcript record pauses the turn", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)

    task = Task.async(fn -> TranscriptTurn.run(turn_session(tmux, path), "do work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)
    File.write!(path, api_error_record(), [:append])

    assert {:paused, %{kind: :usage_limit_exhausted, reason: reason}} = drain_pane_pid(tmux, task)
    assert reason =~ "rate_limit_error"
  end

  test "assistant quota text still completes the turn", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)

    task = Task.async(fn -> TranscriptTurn.run(turn_session(tmux, path), "do work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)
    File.write!(path, completion_record("The rate limit and quota words are in this sentence."), [:append])

    assert {:ok, %{result: :completed}} = drain_pane_pid(tmux, task)
  end

  test "non-limit API-error transcript record fails the turn", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)

    task = Task.async(fn -> TranscriptTurn.run(turn_session(tmux, path), "do work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)
    File.write!(path, api_error_record(400, "invalid_request_error"), [:append])

    assert {:error, {:turn_failed, %{"error" => %{"status" => 400}}}} = drain_pane_pid(tmux, task)
  end

  test "pause_agent parks as {:paused, payload} with session_id/thread_id/turn_id even when pause-confirm expires", %{tmux: tmux} do
    path = temp_transcript()
    on_exit(fn -> File.rm(path) end)

    session = turn_session(tmux, path)

    task =
      Task.async(fn ->
        TranscriptTurn.run(session, "work", poll_interval_ms: 10, pause_confirm_ms: 50)
      end)

    expect_prompt_submit(tmux)

    send(task.pid, {:pause_agent, 77})

    # No completion record appended — pause-confirm expires
    assert {:paused, payload} = pump_until_pause(tmux, task)
    assert payload.request_id == 77
    assert is_binary(payload.session_id)
    assert is_binary(payload.thread_id)
    assert is_binary(payload.turn_id)
  end
end
