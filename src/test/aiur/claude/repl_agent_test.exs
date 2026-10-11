defmodule Aiur.Claude.ReplAgentTest do
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
          process_group_fun: fn pid -> pid end,
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
    assert String.contains?(cmd, "-e BASH_ENV= -e ENV= -e ZDOTDIR=/dev/null")
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
      dir = Aiur.TestSupport.tmp_root!("repl-resume-id")
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
    projects_dir = Aiur.TestSupport.tmp_root!("repl-resume")
    on_exit(fn -> File.rm_rf(projects_dir) end)
    slug_dir = Path.join(projects_dir, RemoteControl.workspace_slug(ws))
    File.mkdir_p!(slug_dir)
    File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          process_group_fun: fn pid -> pid end,
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
          process_group_fun: fn pid -> pid end,
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
    projects_dir = Aiur.TestSupport.tmp_root!("repl-rc-resume")
    on_exit(fn -> File.rm_rf(projects_dir) end)
    slug_dir = Path.join(projects_dir, RemoteControl.workspace_slug(ws))
    File.mkdir_p!(slug_dir)
    File.write!(Path.join(slug_dir, sid <> ".jsonl"), "{}\n")

    task =
      Task.async(fn ->
        ReplAgent.start_session(ws,
          tmux: tmux,
          process_group_fun: fn pid -> pid end,
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
          process_group_fun: fn pid -> pid end,
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
          process_group_fun: fn pid -> pid end,
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
          process_group_fun: fn pid -> pid end,
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
    assert_receive {:tmux_mock_out, "display-message -p -t %8 \#{pane_pid}"}, 1_000
    respond(tmux, "2147480000\n")
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
          process_group_fun: fn pid -> pid end,
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

      {:tmux_mock_out, "display-message -p -t " <> pane_query} ->
        assert pane_query == "#{pane} \#{pane_pid}"
        respond(tmux, "5050\n")
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
          process_group_fun: fn pid -> pid end,
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
      os_pid: 2_147_480_000,
      process_group_id: 2_147_480_000,
      process_group_identity: :gone,
      workspace: System.tmp_dir!(),
      transcript_path: nil,
      model: nil,
      remote_control: false,
      rc_name: "x",
      tmux: tmux
    }

    task = Task.async(fn -> ReplAgent.stop_session(session) end)

    assert_receive {:tmux_mock_out, "display-message -p -t %88 \#{pane_pid}"}, 1_000
    respond_error(tmux, "can't find pane\n")

    assert_receive {:tmux_mock_out, "kill-pane -t %88"}, 1_000
    respond(tmux, "")

    # Teardown then verifies the pane is gone before logging the outcome.
    assert_receive {:tmux_mock_out, "display-message -p -t %88 \#{pane_pid}"}, 1_000
    respond_error(tmux, "can't find pane\n")

    assert {:ok, :cleanup_proven} = Task.await(task, 2_000)
  end
end
