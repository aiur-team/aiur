defmodule Aiur.Claude.Repl.HookTurnTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.HookEvents
  alias Aiur.Claude.Repl.HookTurn
  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{tmux: name}
  end

  defp respond(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
  end

  defp respond_error(tmux, body) do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%error 1 1 0\n"})
  end

  defp hook_session(tmux, identifier) do
    %{
      backend: "claude-repl",
      pane_id: "%50",
      os_pid: 4242,
      workspace: System.tmp_dir!(),
      transcript_path: nil,
      model: nil,
      remote_control: true,
      rc_name: "x",
      identifier: identifier,
      tmux: tmux
    }
  end

  # Drive prompt submission through the mock — paste + capture (no chip) + capture (chip) + Enter.
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

  # Drain pane-liveness polls until task yields a result.
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

  defp await_provider_delivery(tmux) do
    receive do
      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        await_provider_delivery(tmux)

      {:provider_delivered, metadata} ->
        metadata
    after
      1_000 -> flunk("provider delivery acknowledgement did not arrive")
    end
  end

  test "pause_agent mid-turn interrupts (Ctrl+C) and returns {:paused, %{request_id: ^id}}", %{
    tmux: tmux
  } do
    identifier = "HT-PAUSE-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    send(task.pid, {:pause_agent, 42})

    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    respond(tmux, "4242\n")

    assert_receive {:tmux_mock_out, "send-keys -t %50 C-c"}, 1_000
    respond(tmux, "")

    assert {:paused, payload} = Task.await(task, 3_000)
    assert payload.request_id == 42
  end

  test "a failed pause interrupt returns an error rather than a paused acknowledgement", %{tmux: tmux} do
    identifier = "HT-PAUSE-FAIL-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)
    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)
    send(task.pid, {:pause_agent, 43})

    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    respond(tmux, "4242\n")
    assert_receive {:tmux_mock_out, "send-keys -t %50 C-c"}, 1_000
    respond_error(tmux, "no such pane\n")

    assert {:error, {:pause_interrupt_failed, _reason}} = Task.await(task, 3_000)
  end

  test "fully silent session returns {:error, :turn_timeout} after backstop", %{tmux: tmux} do
    identifier = "HT-TIMEOUT-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        HookTurn.run(session, "work", poll_interval_ms: 10, turn_timeout_ms: 100)
      end)

    expect_prompt_submit(tmux)

    assert {:error, :turn_timeout} = drain_pane_pid(tmux, task)
  end

  test "post_tool_use hook resets the deadline so the loop survives past the original timeout", %{
    tmux: tmux
  } do
    identifier = "HT-RESET-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        # 200ms backstop — will expire but PostToolUse keeps resetting it
        HookTurn.run(session, "work", poll_interval_ms: 10, turn_timeout_ms: 200)
      end)

    expect_prompt_submit(tmux)

    # Dispatch heartbeats from a background task while the main process
    # drains pane-alive polls. Without this split, the HookTurn loop is
    # blocked in pane_alive? while the test sleeps — PostToolUse events
    # accumulate in the mailbox but never reset the deadline before it
    # expires, causing a spurious :turn_timeout.
    heartbeater =
      Task.async(fn ->
        for _ <- 1..6 do
          Process.sleep(50)

          HookEvents.dispatch(identifier, %{
            "hook_event_name" => "PostToolUse",
            "tool_name" => "Read"
          })
        end

        HookEvents.dispatch(identifier, %{
          "hook_event_name" => "Stop",
          "last_assistant_message" => "done",
          "session_id" => "sess-reset"
        })
      end)

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.result == :completed
    Task.await(heartbeater, 2_000)
  end

  test "Stop with a session id returns that raw id as thread_id", %{tmux: tmux} do
    identifier = "HT-SESSID-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "Stop",
      "last_assistant_message" => "ok",
      "session_id" => "real-session-id"
    })

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.thread_id == "real-session-id"
    assert result.session_id == "real-session-id"
  end

  test "acknowledges provider delivery only after a provider hook", %{tmux: tmux} do
    identifier = "HT-DELIVERY-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)
    parent = self()

    task =
      Task.async(fn ->
        HookTurn.run(session, "work",
          poll_interval_ms: 10,
          on_provider_delivery: fn metadata ->
            send(parent, {:provider_delivered, metadata})
          end
        )
      end)

    expect_prompt_submit(tmux)
    refute_receive {:provider_delivered, _metadata}, 50

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "UserPromptSubmit",
      "session_id" => "session-delivery"
    })

    assert %{transport: :claude_hook, session_id: "session-delivery"} =
             await_provider_delivery(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "Stop",
      "last_assistant_message" => "done",
      "session_id" => "session-delivery"
    })

    assert {:ok, _result} = drain_pane_pid(tmux, task)
    refute_receive {:provider_delivered, _metadata}, 50
  end

  test "structured API usage-limit failure pauses the turn", %{tmux: tmux} do
    identifier = "HT-LIMIT-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "StopFailure",
      "error" => "rate_limit",
      "error_details" => "429 Too Many Requests",
      "last_assistant_message" => "API Error: Rate limit reached"
    })

    assert {:paused, %{kind: :usage_limit_exhausted, reason: reason}} = drain_pane_pid(tmux, task)
    assert reason =~ "rate_limit"
  end

  test "assistant text mentioning a quota does not pause a healthy turn", %{tmux: tmux} do
    identifier = "HT-QUOTA-TEXT-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "Stop",
      "last_assistant_message" => "The quota and rate limit terminology is documented here."
    })

    assert {:ok, %{result: :completed}} = drain_pane_pid(tmux, task)
  end

  test "non-limit StopFailure fails the turn immediately", %{tmux: tmux} do
    identifier = "HT-FAILURE-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "StopFailure",
      "error" => "authentication_failed",
      "last_assistant_message" => "Invalid API key"
    })

    assert {:error, {:turn_failed, %{"error" => "authentication_failed"}}} =
             drain_pane_pid(tmux, task)
  end

  test "Stop with no session id returns thread_id == nil and a fallback session_id", %{tmux: tmux} do
    identifier = "HT-NOSESSID-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 10) end)

    expect_prompt_submit(tmux)

    HookEvents.dispatch(identifier, %{
      "hook_event_name" => "Stop",
      "last_assistant_message" => "ok"
    })

    assert {:ok, result} = drain_pane_pid(tmux, task)
    # thread_id is nil when hook never carried a session id
    assert result.thread_id == nil
    # session_id falls back to the synthetic repl-<n> display value
    assert is_binary(result.session_id)
    assert String.starts_with?(result.session_id, "repl-")
  end
end
