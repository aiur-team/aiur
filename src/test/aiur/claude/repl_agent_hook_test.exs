defmodule Aiur.Claude.ReplAgentHookTest do
  use ExUnit.Case, async: true

  alias Aiur.Tmux

  alias Aiur.Claude.HookEvents
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

  defp turn_session(tmux, transcript_path, pane) do
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

  # --------------------------------------------------- hook-driven turn detection

  # A session carrying an :identifier routes run_turn to the hook path — no
  # transcript file is read; turn completion rides on the Stop lifecycle hook.
  defp hook_session(tmux, identifier, pane \\ "%50") do
    tmux
    |> turn_session(nil, pane)
    |> Map.merge(%{remote_control: true, identifier: identifier})
  end

  # The hook path pastes, waits (read-only) for the paste to land in the input
  # box, then submits with Enter — and never clears/retypes the line. Answer one
  # capture-pane without the chip (it must keep polling, never send C-u), then
  # one with the chip so Enter fires.
  defp expect_hook_prompt_submit(tmux) do
    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")

    # Paste not landed yet: must keep waiting, must NOT clear the line.
    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "")
    refute_receive {:tmux_mock_out, "send-keys -t %50 C-u"}, 50

    # Chip present: the paste landed, so Enter submits it.
    assert_receive {:tmux_mock_out, "capture-pane" <> _}, 1_000
    respond(tmux, "[Pasted text +5 lines]\n")

    assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
    respond(tmux, "")
    :ok
  end

  test "hook-driven submit waits for the paste to land before Enter and never clears the input",
       %{tmux: tmux} do
    identifier = "MT-HOOKSUBMIT-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{}, poll_interval_ms: 10)
      end)

    # Enter must follow the paste only once the input echoes it — firing Enter
    # immediately races the paste-buffer and leaves the prompt unsubmitted, so
    # claude never starts a turn and no hooks fire. The wait is read-only: it
    # never sends C-u (that reads as an interrupt that cancels a live turn).
    expect_hook_prompt_submit(tmux)

    :ok =
      HookEvents.dispatch(identifier, %{
        "hook_event_name" => "Stop",
        "last_assistant_message" => "ok"
      })

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.result == :completed
    assert result.message == "ok"
  end

  test "hook-driven submit still Enters best-effort when the paste never echoes, never clearing or failing",
       %{tmux: tmux} do
    identifier = "MT-HOOKFOLD-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{}, poll_interval_ms: 10, prompt_confirm_ms: 40)
      end)

    # A mid-turn fold clears the input box, so the paste chip never appears.
    # Submit must not clear/retry or fail the run — it Enters best-effort once
    # the confirm budget elapses and lets the UserPromptSubmit hook confirm.
    assert_receive {:tmux_mock_out, "load-buffer " <> _}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "paste-buffer " <> _}, 1_000
    respond(tmux, "")

    drain_captures_until_enter(tmux)

    :ok =
      HookEvents.dispatch(identifier, %{
        "hook_event_name" => "Stop",
        "last_assistant_message" => "ok"
      })

    assert {:ok, %{result: :completed}} = drain_pane_pid(tmux, task)
  end

  # Answer capture-pane polls with no chip (the paste never echoes) until the
  # submit gives up waiting and Enters. Fails loudly if it ever clears the line.
  defp drain_captures_until_enter(tmux) do
    receive do
      {:tmux_mock_out, "capture-pane" <> _} ->
        respond(tmux, "")
        drain_captures_until_enter(tmux)

      {:tmux_mock_out, "send-keys -t %50 C-u"} ->
        flunk("submit must never clear the input line")

      {:tmux_mock_out, "send-keys -t %50 Enter"} ->
        respond(tmux, "")
        :ok
    after
      2_000 -> flunk("submit never reached Enter")
    end
  end

  test "hook-driven run_turn completes on a Stop hook and emits no display transcript itself",
       %{tmux: tmux} do
    identifier = "MT-HOOKTURN-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)
    tp = self()

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{},
          on_message: fn m -> send(tp, {:msg, m}) end,
          poll_interval_ms: 10
        )
      end)

    # The prompt is pasted and submitted; the hook path does not scrape the echo.
    expect_hook_prompt_submit(tmux)

    # PostToolUse is a liveness heartbeat for turn detection only; Stop carries
    # the answer for the runner's bookkeeping. Neither paints the pane — the
    # conversation is rendered by Aiur.Claude.DisplayTailer from the transcript.
    :ok = HookEvents.dispatch(identifier, %{"hook_event_name" => "PostToolUse", "tool_name" => "Bash"})

    :ok =
      HookEvents.dispatch(identifier, %{
        "hook_event_name" => "Stop",
        "last_assistant_message" => "All done.",
        "session_id" => "sess-1"
      })

    assert {:ok, result} = drain_pane_pid(tmux, task)
    assert result.result == :completed
    assert result.message == "All done."
    assert result.session_id == "sess-1"

    # The hook loop emits control events only — no `→ Tool` or assistant rows.
    refute_received {:msg, %{event: :transcript, transcript_event: %{role: :tool}}}
    refute_received {:msg, %{event: :transcript, transcript_event: %{role: :assistant}}}

    assert_receive {:msg, %{event: :turn_completed}}, 1000
  end

  test "hook-driven run_turn types a mid-turn operator message into the pane", %{tmux: tmux} do
    identifier = "MT-HOOKOP-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{},
          on_operator_message: fn ->
            {:deliver_text, "INTERJECT-MSG", fn _ -> :ok end, fn _ -> :ok end}
          end,
          poll_interval_ms: 10
        )
      end)

    expect_hook_prompt_submit(tmux)

    # An operator message lands mid-turn (immediate-delivery broadcast). The hook
    # loop must type it straight into the live REPL pane.
    send(task.pid, {:agent_queue_updated, identifier, 1, true})
    assert_operator_typed(tmux, "INTERJECT-MSG")

    :ok = HookEvents.dispatch(identifier, %{"hook_event_name" => "Stop", "last_assistant_message" => "done"})
    assert {:ok, %{result: :completed}} = drain_pane_pid(tmux, task)
  end

  # Drain pane-liveness polls until the operator text is typed (send-keys -l) and
  # submitted (Enter).
  defp assert_operator_typed(tmux, text) do
    receive do
      {:tmux_mock_out, "send-keys -t %50 -l " <> rest} ->
        assert rest =~ text
        respond(tmux, "")
        assert_receive {:tmux_mock_out, "send-keys -t %50 Enter"}, 1_000
        respond(tmux, "")
        :ok

      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        assert_operator_typed(tmux, text)

      {:tmux_mock_out, _other} ->
        respond(tmux, "")
        assert_operator_typed(tmux, text)
    after
      3_000 -> flunk("operator text never typed into the pane")
    end
  end

  test "hook-driven run_turn returns :repl_gone when the pane dies mid-turn", %{tmux: tmux} do
    identifier = "MT-HOOKGONE-#{System.unique_integer([:positive])}"
    session = hook_session(tmux, identifier)

    task =
      Task.async(fn ->
        ReplAgent.run_turn(session, "do the thing", %{}, poll_interval_ms: 10)
      end)

    expect_hook_prompt_submit(tmux)

    # First liveness poll reports the pane gone -> :repl_gone (no Stop needed).
    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    respond_error(tmux, "no server running")

    assert {:error, :repl_gone} = Task.await(task, 2_000)
  end
end
