defmodule Aiur.Claude.ReplAgentTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.HookEvents
  alias Aiur.Claude.RemoteControl
  alias Aiur.Claude.ReplAgent
  alias Aiur.Tmux

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

  defp available_hook_settings(true, identifier) when is_binary(identifier),
    do: "/tmp/aiur-test-hooks-#{identifier}.json"

  test "start_session spawns the REPL, awaits readiness, and returns a session", %{tmux: tmux} do
    # Normalize up front: start_session stores the expanded path, and on macOS
    # System.tmp_dir!/0 carries a trailing slash that Path.expand strips.
    ws = Path.expand(System.tmp_dir!())

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          model: "claude-opus-4-8",
          effort: "max",
          rc_name: "aiur-repl-test",
          window_name: "aiur-repl-test",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    # 1. new-window spawns the pane.
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window -d -n aiur-repl-test")
    assert String.contains?(cmd, "exec claude")
    assert String.contains?(cmd, "--model 'claude-opus-4-8'")
    assert String.contains?(cmd, "--effort 'max'")
    refute String.contains?(cmd, "--remote-control")
    respond(tmux, "%99\n")

    # 2. pane_pid resolves the OS pid before the containment callback.
    assert_receive {:tmux_mock_out, "display-message -p -t %99 \#{pane_pid}"}, 1_000
    respond(tmux, "4242\n")

    # 3. await_ready captures the pane until the prompt glyph shows.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %99"}, 1_000
    respond(tmux, "Welcome\n❯\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.backend == "claude-repl"
    assert session.pane_id == "%99"
    assert session.os_pid == 4242
    assert session.workspace == ws
    assert session.model == "claude-opus-4-8"
    assert session.remote_control == false
    assert session.transcript_path == nil
    assert session.session_url == nil
  end

  describe "resume_session_id/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "repl-resume-id-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{projects_dir: dir, workspace: "/ws/aiur/613"}
    end

    test "returns the session id when its transcript exists on disk", %{projects_dir: dir, workspace: ws} do
      sid = "sess-abc"
      slug_dir = Path.join(dir, RemoteControl.workspace_slug(ws))
      File.mkdir_p!(slug_dir)
      File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

      assert ReplAgent.resume_session_id([resume_thread_id: sid, projects_dir: dir], ws) == sid
    end

    test "returns nil when the transcript is gone (graceful clean start)", %{projects_dir: dir, workspace: ws} do
      # A handle pointing at a vanished transcript (workspace recloned without the
      # host-local jsonl) must degrade to a clean start, not strand the issue.
      assert ReplAgent.resume_session_id([resume_thread_id: "gone", projects_dir: dir], ws) == nil
    end

    test "returns nil with no/blank resume id (first dispatch, or cleared handle)", %{projects_dir: dir, workspace: ws} do
      assert ReplAgent.resume_session_id([projects_dir: dir], ws) == nil
      assert ReplAgent.resume_session_id([resume_thread_id: nil, projects_dir: dir], ws) == nil
      assert ReplAgent.resume_session_id([resume_thread_id: "", projects_dir: dir], ws) == nil
    end
  end

  test "start_session passes --resume and marks the session resumed when the transcript exists", %{tmux: tmux} do
    ws = "/ws/aiur/613"
    sid = "sess-#{System.unique_integer([:positive])}"
    projects_dir = Path.join(System.tmp_dir!(), "repl-resume-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(projects_dir) end)
    slug_dir = Path.join(projects_dir, RemoteControl.workspace_slug(ws))
    File.mkdir_p!(slug_dir)
    File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          rc_name: "aiur-repl-test",
          window_name: "aiur-repl-test",
          projects_dir: projects_dir,
          resume_thread_id: sid
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--resume '#{sid}'")
    respond(tmux, "%55\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %55 \#{pane_pid}"}, 1_000
    respond(tmux, "4242\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %55"}, 1_000
    respond(tmux, "❯\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.resumed == true
    assert session.thread_id == sid
  end

  test "start_session omits --resume and stays a clean start when the transcript is gone", %{tmux: tmux} do
    ws = "/ws/aiur/613"

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          rc_name: "aiur-repl-test",
          window_name: "aiur-repl-test",
          projects_dir: "/nonexistent-projects-dir",
          resume_thread_id: "vanished-session"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    refute String.contains?(cmd, "--resume")
    respond(tmux, "%56\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %56 \#{pane_pid}"}, 1_000
    respond(tmux, "4242\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %56"}, 1_000
    respond(tmux, "❯\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.resumed == false
    assert session.thread_id == nil
  end

  test "start_session passes both --remote-control and --resume on a resumed RC session (the model:remote path)", %{tmux: tmux} do
    # `model:remote` forces RC on, so the canonical claude-repl resume path
    # spawns the interactive `claude` carrying BOTH flags. Pin the command form
    # so a regression is caught; the combination's live acceptance is verified
    # against the real CLI (see PR notes), and a spawn failure degrades to
    # headless via `AgentRunner.start_agent_session/3` rather than stranding.
    ws = "/ws/aiur/613"
    sid = "sess-#{System.unique_integer([:positive])}"
    projects_dir = Path.join(System.tmp_dir!(), "repl-rc-resume-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(projects_dir) end)
    slug_dir = Path.join(projects_dir, RemoteControl.workspace_slug(ws))
    File.mkdir_p!(slug_dir)
    File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          remote_control: true,
          identifier: "rc-resume",
          hook_settings_fun: &available_hook_settings/2,
          rc_name: "aiur-rc-resume",
          window_name: "aiur-rc-resume",
          projects_dir: projects_dir,
          resume_thread_id: sid
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control 'aiur-rc-resume'")
    assert String.contains?(cmd, "--resume '#{sid}'")
    respond(tmux, "%71\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %71 \#{pane_pid}"}, 1_000
    respond(tmux, "10\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %71"}, 1_000
    respond(tmux, "❯\n")

    # RC sessions scan the pane once ready for the `/remote-control … URL` banner.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %71"}, 1_000
    respond(tmux, "  /remote-control is active · https://claude.ai/code/session_01RcResume\n❯\n")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.remote_control == true
    assert session.resumed == true
    assert session.thread_id == sid
  end

  test "start_session passes --remote-control when opted in", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          remote_control: true,
          identifier: "rc-command",
          hook_settings_fun: &available_hook_settings/2,
          rc_name: "aiur-rc-test",
          window_name: "aiur-rc-test",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control 'aiur-rc-test'")
    respond(tmux, "%7\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %7 \#{pane_pid}"}, 1_000
    respond(tmux, "10\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    respond(tmux, "❯\n")

    # RC sessions scan the pane once ready for the `/remote-control … URL` banner.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000

    respond(
      tmux,
      "  /remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_01LguPUDk5vT6Tt31FH2KUmG\n❯\n"
    )

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.remote_control == true
    assert session.session_url == "https://claude.ai/code/session_01LguPUDk5vT6Tt31FH2KUmG"
  end

  test "start_session harvests the RC URL via /rc when only the footer indicator shows", %{tmux: tmux} do
    # claude 2.1.175 dropped the startup banner; RC attach is announced only
    # by a tiny `/rc active` footer note. The URL must be harvested by
    # running `/rc` and dismissing its dialog with Esc.
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          remote_control: true,
          identifier: "rc-harvest",
          hook_settings_fun: &available_hook_settings/2,
          rc_name: "aiur-rc-test",
          window_name: "aiur-rc-test",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control 'aiur-rc-test'")
    respond(tmux, "%7\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %7 \#{pane_pid}"}, 1_000
    respond(tmux, "10\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    respond(tmux, "❯\n")

    # RC evidence scan: no banner URL, but the footer shows `/rc active`.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000
    respond(tmux, "❯\n  ⏵⏵ accept edits on (shift+tab to cycle) · /rc active\n")

    # The driver types /rc, submits, scrapes the dialog, then dismisses it.
    assert_receive {:tmux_mock_out, "send-keys -t %7 -l /rc"}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "send-keys -t %7 Enter"}, 1_000
    respond(tmux, "")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %7"}, 1_000

    respond(
      tmux,
      "  Remote Control\n  This session is available in the Claude mobile app and at https://claude.ai/code/session_01TestHarvestUrl42.\n  ❯ Continue\n"
    )

    assert_receive {:tmux_mock_out, "send-keys -t %7 Escape"}, 1_000
    respond(tmux, "")

    assert {:ok, session} = Task.await(task, 2_000)
    assert session.remote_control == true
    assert session.session_url == "https://claude.ai/code/session_01TestHarvestUrl42"
  end

  test "start_session degrades to :remote_control_unavailable when the RC banner never appears", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          remote_control: true,
          identifier: "rc-unavailable",
          hook_settings_fun: &available_hook_settings/2,
          rc_name: "aiur-rc-test",
          window_name: "aiur-rc-test",
          # 0ms budget: the first banner-less capture exhausts it, so RC is
          # judged unavailable and the session degrades.
          url_capture_timeout_ms: 0,
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.contains?(cmd, "--remote-control 'aiur-rc-test'")
    respond(tmux, "%8\n")

    assert_receive {:tmux_mock_out, "display-message -p -t %8 \#{pane_pid}"}, 1_000
    # A safe, certainly-dead pid so the degradation's graceful_kill is a no-op.
    respond(tmux, "2147480000\n")

    assert_receive {:tmux_mock_out, "capture-pane -p -t %8"}, 1_000
    respond(tmux, "❯\n")

    # RC banner scan finds no `claude.ai/code/session_…` URL.
    assert_receive {:tmux_mock_out, "capture-pane -p -t %8"}, 1_000
    respond(tmux, "❯\n")

    # An unattached RC pane must be torn down, not left leaking.
    assert_receive {:tmux_mock_out, "kill-pane -t %8"}, 1_000
    respond(tmux, "")
    assert_receive {:tmux_mock_out, "display-message -p -t %8 \#{pane_pid}"}, 1_000
    respond_error(tmux, "no pane\n")

    assert {:error, :remote_control_unavailable} = Task.await(task, 2_000)
  end

  test "start_session kills the pane and errors when the REPL never becomes ready", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          window_name: "aiur-noready",
          ready_timeout_ms: 0,
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    respond(tmux, "%5\n")

    # Readiness polls capture-pane; never show the prompt. With a 0ms deadline
    # the first non-matching capture exhausts the budget and the pane is killed.
    drain_until_kill(tmux, "%5", task)
  end

  # Keep answering capture-pane (no prompt) until the readiness deadline
  # elapses and start_session issues kill-pane, then assert the error.
  defp drain_until_kill(tmux, pane, task) do
    receive do
      {:tmux_mock_out, "capture-pane -p -t " <> ^pane} ->
        respond(tmux, "still booting\n")
        drain_until_kill(tmux, pane, task)

      {:tmux_mock_out, "kill-pane -t " <> ^pane} ->
        respond(tmux, "")
        assert_receive {:tmux_mock_out, pane_query}, 1_000
        assert pane_query == "display-message -p -t #{pane} \#{pane_pid}"
        respond_error(tmux, "no pane\n")
        assert {:error, :repl_not_ready} = Task.await(task, 2_000)
    after
      2_000 -> flunk("did not observe kill-pane within timeout")
    end
  end

  test "start_session surfaces a spawn error without awaiting readiness", %{tmux: tmux} do
    ws = System.tmp_dir!()

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          window_name: "aiur-fail",
          projects_dir: "/nonexistent-projects-dir"
        )
      end)

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert String.starts_with?(cmd, "new-window")
    respond_error(tmux, "no server running\n")

    assert {:error, _} = Task.await(task, 2_000)
    refute_receive {:tmux_mock_out, "capture-pane" <> _}, 200
  end

  test "stop_session kills the pane and graceful-kills the os pid", %{tmux: tmux} do
    session = %{
      backend: "claude-repl",
      pane_id: "%88",
      os_pid: nil,
      workspace: System.tmp_dir!(),
      transcript_path: nil,
      model: nil,
      remote_control: false,
      rc_name: "x",
      tmux: tmux
    }

    task = Task.async(fn -> ReplAgent.stop_session(session) end)

    assert_receive {:tmux_mock_out, "kill-pane -t %88"}, 1_000
    respond(tmux, "")

    # Teardown then verifies the pane is gone before logging the outcome.
    assert_receive {:tmux_mock_out, "display-message -p -t %88 \#{pane_pid}"}, 1_000
    respond_error(tmux, "can't find pane\n")

    assert :ok = Task.await(task, 2_000)
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
    path = Path.join(System.tmp_dir!(), "repl-turn-#{System.unique_integer([:positive])}.jsonl")
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

    assert_receive {:msg, %{event: :session_started, turn_id: tid}}
    assert tid == result.turn_id
    assert_receive {:msg, %{event: :transcript, transcript_event: %{role: :assistant, body: "All done."}}}
    assert_receive {:msg, %{event: :turn_completed}}
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
    ws = Path.join(System.tmp_dir!(), "repl-cold-#{System.unique_integer([:positive])}")
    projects_dir = Path.join(System.tmp_dir!(), "repl-proj-#{System.unique_integer([:positive])}")
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

  # Never append a record after the C-c: the pause-confirm deadline expires
  # and the turn still parks as paused (never {:error, :turn_timeout}).
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

  test "pause-confirm deadline expiry still parks the agent as paused", %{tmux: tmux} do
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

    assert {:paused, %{request_id: 7}} = pump_pause_no_turn_end(tmux, task)
  end

  # A failed C-c (tmux error) must not crash the turn — park as paused.
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

  test "a failed interrupt send still parks the agent as paused", %{tmux: tmux} do
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

    assert {:paused, %{request_id: 9}} = pump_pause_interrupt_fails(tmux, task)
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

    assert_receive {:msg, %{event: :turn_completed}}
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
