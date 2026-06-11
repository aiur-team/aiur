defmodule Aiur.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner

  # Regression: open_aiur_turn_streams posted the `__aiur_turn__:<id>`
  # marker SYNCHRONOUSLY in a for-loop, one POST per attached
  # opencode-serve. Each POST blocks until opencode's chat-completion
  # to our bridge returns — which, by design, holds for the entire
  # codex turn (often minutes). With Req's 30s receive_timeout, every
  # attached server stalled the loop for 30 s, and with 3 slots a
  # fresh agent waited ~90 s between dispatch and actually starting
  # its codex turn — the chat pane sat empty for that whole window.
  #
  # The fix: fire the marker posts asynchronously (Task.start) so
  # `post_aiur_turn_markers/4` returns immediately. The bridge still
  # gets its chat-completion request once opencode receives the
  # synthetic user message; we just don't block the codex turn on it.
  describe "post_aiur_turn_markers/4" do
    test "returns immediately even when post_fn would block for tens of seconds" do
      writers = [
        %{session_id: "ses_1", base_url: "http://127.0.0.1:9991"},
        %{session_id: "ses_2", base_url: "http://127.0.0.1:9992"},
        %{session_id: "ses_3", base_url: "http://127.0.0.1:9993"}
      ]

      slow_post = fn _base, _sid, _payload ->
        # Simulate Req's 30s receive_timeout — what real opencode-serves
        # do while their chat-completion to our bridge is open.
        Process.sleep(30_000)
        {:ok, %{}}
      end

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          AgentRunner.post_aiur_turn_markers("99", "tTEST", writers, slow_post)
        end)

      elapsed_ms = div(elapsed_us, 1000)

      assert elapsed_ms < 500,
             "post_aiur_turn_markers should return immediately (fire-and-forget) — took #{elapsed_ms}ms with 3 slow writers"
    end

    test "still invokes the post function for every attached writer" do
      writers = [
        %{session_id: "ses_a", base_url: "http://opencode-a"},
        %{session_id: "ses_b", base_url: "http://opencode-b"}
      ]

      parent = self()

      observing_post = fn base, sid, payload ->
        send(parent, {:posted, base, sid, payload})
        {:ok, %{}}
      end

      :ok = AgentRunner.post_aiur_turn_markers("101", "tABC", writers, observing_post)

      # The posts are asynchronous; give them a moment to land.
      assert_receive {:posted, "http://opencode-a", "ses_a", payload_a}, 1_000
      assert_receive {:posted, "http://opencode-b", "ses_b", payload_b}, 1_000

      for payload <- [payload_a, payload_b] do
        assert %{parts: [part]} = payload
        assert part["type"] == "text"
        assert part["text"] == "__aiur_turn__:tABC"
        assert part["synthetic"] == true
      end
    end

    test "swallows post errors so a failing opencode-serve does not crash agent_runner" do
      writers = [%{session_id: "ses_x", base_url: "http://gone"}]

      failing_post = fn _base, _sid, _payload -> {:error, :nxdomain} end

      # Should not raise, should return :ok, should not blow up the
      # caller (agent_runner) even though the underlying post failed.
      assert :ok = AgentRunner.post_aiur_turn_markers("42", "tFAIL", writers, failing_post)
    end

    test "empty writer list is a no-op" do
      assert :ok = AgentRunner.post_aiur_turn_markers("13", "tNONE", [], fn _, _, _ -> :ok end)
    end
  end

  describe "start_agent_session/3" do
    test "tags the started session with its backend" do
      start_fun = fn _workspace, _opts -> {:ok, %{handle: :h}} end

      assert {:ok, session} =
               AgentRunner.start_agent_session("/ws", [backend: "codex", model: nil], start_fun)

      assert session.backend == "codex"
    end

    test "claude-repl start failure falls back to headless claude" do
      parent = self()

      start_fun = fn _workspace, opts ->
        send(parent, {:attempt, Keyword.fetch!(opts, :backend), Keyword.get(opts, :remote_control)})

        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{handle: :headless}}
        end
      end

      assert {:ok, session} =
               AgentRunner.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: "opus", remote_control: true],
                 start_fun
               )

      assert session.backend == "claude"
      # The REPL attempt carries the RC opt-in; the headless retry drops it.
      assert_received {:attempt, "claude-repl", true}
      assert_received {:attempt, "claude", nil}
    end

    test "a non-repl backend failure does NOT fall back" do
      start_fun = fn _workspace, _opts -> {:error, :boom} end

      assert {:error, :boom} =
               AgentRunner.start_agent_session("/ws", [backend: "claude", model: nil], start_fun)
    end

    test "a repl failure whose headless retry also fails surfaces the retry error" do
      start_fun = fn _workspace, opts ->
        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:error, :headless_down}
        end
      end

      assert {:error, :headless_down} =
               AgentRunner.start_agent_session("/ws", [backend: "claude-repl", model: nil], start_fun)
    end
  end

  describe "maybe_trust_remote_control_workspace/4" do
    test "trusts the workspace for a local RC dispatch" do
      parent = self()
      trust_fun = fn ws -> send(parent, {:trusted, ws}) && :ok end

      assert :ok = AgentRunner.maybe_trust_remote_control_workspace("/ws/9", true, nil, trust_fun)
      assert_received {:trusted, "/ws/9"}
    end

    test "does not trust when RC is off" do
      trust_fun = fn _ws -> flunk("trust must not run for non-RC dispatch") end
      assert :ok = AgentRunner.maybe_trust_remote_control_workspace("/ws/9", false, nil, trust_fun)
    end

    test "does not trust a remote-worker dispatch (RC is local-only)" do
      trust_fun = fn _ws -> flunk("trust must not run for a remote worker host") end
      assert :ok = AgentRunner.maybe_trust_remote_control_workspace("/ws/9", true, "box-2", trust_fun)
    end

    test "a trust failure is swallowed so the issue is not stranded" do
      trust_fun = fn _ws -> {:error, :enoent} end

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = AgentRunner.maybe_trust_remote_control_workspace("/ws/9", true, nil, trust_fun)
      end)
    end
  end

  describe "rc_session_name/1" do
    test "builds the operator-facing chat title from identifier and title" do
      issue = %{identifier: "99", id: "gid-99", title: "Add greeting"}
      assert AgentRunner.rc_session_name(issue) == "Aiur 99 - Add greeting"
    end

    test "falls back to id when identifier is nil" do
      issue = %{identifier: nil, id: "212", title: "Fix it"}
      assert AgentRunner.rc_session_name(issue) == "Aiur 212 - Fix it"
    end

    test "strips control chars and quotes, collapses whitespace" do
      issue = %{identifier: "5", id: "5", title: "a\t'b'\n  `c`"}
      assert AgentRunner.rc_session_name(issue) == "Aiur 5 - a b c"
    end

    test "truncates to 60 characters" do
      issue = %{identifier: "7", id: "7", title: String.duplicate("x", 100)}
      assert String.length(AgentRunner.rc_session_name(issue)) == 60
    end
  end

  # A mid-turn REPL pane death (`:repl_gone`) means the cloud-mediated RC
  # pane vanished while the agent was working — a flaky connection drop or an
  # operator-closed pane, not a broken agent. If `run/3` raised on it, the
  # Task would exit abnormally and the orchestrator would book a *failure*
  # retry (10s backoff, counts against max_retry_attempts), so a few
  # disconnects would make aiur give up on the issue entirely. Treating it as
  # transient lets the run exit cleanly → a cheap continuation re-dispatch
  # with a fresh pane, which is the right recovery for a flaky RC link.
  describe "transient_run_error?/1" do
    test "a mid-turn REPL pane death is transient so the run re-dispatches instead of hard-failing" do
      assert AgentRunner.transient_run_error?(:repl_gone)
    end

    test "a genuine agent failure is NOT transient so it still surfaces as a hard error" do
      refute AgentRunner.transient_run_error?(:prompt_not_delivered)
      refute AgentRunner.transient_run_error?(:no_transcript)
      refute AgentRunner.transient_run_error?({:workspace_prepare_failed, :enoent})
    end
  end
end
