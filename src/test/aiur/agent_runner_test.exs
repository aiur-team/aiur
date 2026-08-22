defmodule Aiur.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner
  alias Aiur.Orchestrator

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

      parent = self()

      slow_post = fn base, sid, _payload ->
        send(parent, {:entered, base, sid})
        # Simulate Req's 30s receive_timeout — what real opencode-serves
        # do while their chat-completion to our bridge is open.
        Process.sleep(30_000)
        {:ok, %{}}
      end

      # A synchronous fan-out would block here for ~90s (3 x 30s) and hang the
      # test until ExUnit's timeout. Reaching the assertion at all proves the
      # call returned without waiting on the posts; a wall-clock bound would be
      # a preemption-sensitive proxy for the same property under load.
      assert :ok = AgentRunner.post_aiur_turn_markers("99", "tTEST", writers, slow_post)

      # Every writer's post still ran, concurrently, in its own fire-and-forget
      # Task — each entered slow_post even though none of them has returned.
      for %{session_id: sid, base_url: base} <- writers do
        assert_receive {:entered, ^base, ^sid}, 5_000
      end
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

    test "missing Remote Control hook listener fails instead of falling back" do
      parent = self()

      start_fun = fn _workspace, opts ->
        send(parent, {:attempt, Keyword.fetch!(opts, :backend)})
        {:error, :remote_control_requires_dashboard}
      end

      assert {:error, :remote_control_requires_dashboard} =
               AgentRunner.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: "opus", remote_control: true],
                 start_fun
               )

      assert_received {:attempt, "claude-repl"}
      refute_received {:attempt, "claude"}
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

  describe "rc_session_name/2" do
    test "builds the operator-facing chat title with repo, id, and title" do
      issue = %{identifier: "7", id: "gid-7", title: "CLI: ENS namespace"}

      assert AgentRunner.rc_session_name(issue, "its-applekid/actions") ==
               "Aiur: Actions #7 - CLI: ENS namespace"
    end

    test "falls back to id when identifier is nil" do
      issue = %{identifier: nil, id: "412", title: "Fix it"}
      assert AgentRunner.rc_session_name(issue, "its-everdred/aiur") == "Aiur: Aiur #412 - Fix it"
    end

    test "preserves existing casing in the repo short name" do
      issue = %{identifier: "1", id: "1", title: "x"}
      assert AgentRunner.rc_session_name(issue, "owner/myRepo") == "Aiur: MyRepo #1 - x"
    end

    test "omits the repo when the tracker exposes none" do
      issue = %{identifier: "9", id: "9", title: "No repo"}
      assert AgentRunner.rc_session_name(issue, nil) == "Aiur: #9 - No repo"
    end

    test "strips control chars and quotes, collapses whitespace" do
      issue = %{identifier: "5", id: "5", title: "a\t'b'\n  `c`"}
      assert AgentRunner.rc_session_name(issue, "owner/repo") == "Aiur: Repo #5 - a b c"
    end

    test "truncates to 60 characters" do
      issue = %{identifier: "7", id: "7", title: String.duplicate("x", 100)}
      assert String.length(AgentRunner.rc_session_name(issue, "owner/repo")) == 60
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

    test "an undelivered prompt is transient so a single failed paste re-dispatches instead of crashing the run" do
      assert AgentRunner.transient_run_error?(:prompt_not_delivered)
    end

    test "a retired app-server port is transient so a fresh generation can replace it" do
      assert AgentRunner.transient_run_error?(:port_closed)
      assert AgentRunner.transient_run_error?({:port_exit, 9})
      assert AgentRunner.transient_run_error?(:port_closed, "codex")
      refute AgentRunner.transient_run_error?(:port_closed, "claude")
      assert AgentRunner.transient_run_error?({:port_exit, 9}, "codex")
      refute AgentRunner.transient_run_error?({:port_exit, 9}, "claude")

      assert AgentRunner.transient_run_error?(
               {:turn_start_failed, :port_closed},
               "codex"
             )

      assert AgentRunner.transient_run_error?(
               {:turn_interrupt_failed, :port_closed},
               "codex"
             )

      refute AgentRunner.transient_run_error?(
               {:turn_start_failed, :port_closed},
               "claude"
             )

      refute AgentRunner.transient_run_error?(
               {:turn_interrupt_failed, :port_closed},
               "claude"
             )
    end

    test "an active-turn mismatch is transient only for Codex" do
      reason =
        {:turn_interrupt_failed,
         %{
           "code" => -32_600,
           "message" => "expected active turn id queued-turn but found prior-turn"
         }}

      assert AgentRunner.transient_run_error?(reason, "codex")
      refute AgentRunner.transient_run_error?(reason, "claude")
    end

    test "a genuine agent failure is NOT transient so it still surfaces as a hard error" do
      refute AgentRunner.transient_run_error?(:no_transcript)
      refute AgentRunner.transient_run_error?({:workspace_prepare_failed, :enoent})
      refute AgentRunner.transient_run_error?({:turn_start_failed, :provider_rejected}, "codex")
    end
  end

  # #768: the delivered-queue bookkeeping RPCs return `{:error, :unavailable}`
  # when the orchestrator is briefly overloaded (an exhausted Codex account
  # floods rateLimit events). AgentRunner hard-matched them with `:ok =`, so
  # that transient overload raised a MatchError, crashed the agent Task, and
  # booked a retry that stalled the ticket. Bookkeeping is best-effort: it must
  # log and continue, never crash.
  describe "best_effort_queue_bookkeeping/3" do
    setup do
      %{issue: %Aiur.Issue{id: "768", identifier: "aiur#768"}}
    end

    test "a successful bookkeeping call is a no-op", %{issue: issue} do
      assert AgentRunner.best_effort_queue_bookkeeping(:ok, :consume, issue) == :ok
    end

    test "an unavailable orchestrator does not raise a MatchError", %{issue: issue} do
      assert AgentRunner.best_effort_queue_bookkeeping({:error, :unavailable}, :consume, issue) ==
               :ok

      assert AgentRunner.best_effort_queue_bookkeeping({:error, :timeout}, :fail, issue) == :ok
    end
  end

  describe "should_display_tail?/3" do
    test "only the hook-driven RC claude-repl session feeds the display tailer" do
      assert AgentRunner.should_display_tail?("claude-repl", true, "101")
    end

    test "a headless-claude fallback, codex, or RC-off REPL gets no second display source" do
      # RC requested but the REPL fell back to headless "claude"
      refute AgentRunner.should_display_tail?("claude", true, "101")
      # codex streams its own transcript
      refute AgentRunner.should_display_tail?("codex", true, "101")
      # claude-repl but RC is off
      refute AgentRunner.should_display_tail?("claude-repl", false, "101")
      # no identifier to scope the hook topic
      refute AgentRunner.should_display_tail?("claude-repl", true, nil)
    end
  end

  describe "resume_thread_id/3 (when to rejoin a prior thread)" do
    test "returns the persisted thread id for a resumable, local backend" do
      assert AgentRunner.resume_thread_id("codex", nil, {:ok, %{thread_id: "thr_1"}}) == "thr_1"
      # claude-repl is resumable too: the id is the prior claude session id.
      assert AgentRunner.resume_thread_id("claude-repl", nil, {:ok, %{thread_id: "sess_1"}}) == "sess_1"
    end

    test "is nil when there is no persisted handle (clean start)" do
      assert AgentRunner.resume_thread_id("codex", nil, :none) == nil
    end

    test "is nil for a non-resumable backend even with a handle" do
      # Headless claude can't resume (its app-server thread map is in-memory only).
      assert AgentRunner.resume_thread_id("claude", nil, {:ok, %{thread_id: "thr_1"}}) == nil
    end

    test "is nil for a remote worker (codex rollouts are host-local)" do
      assert AgentRunner.resume_thread_id("codex", "box-2", {:ok, %{thread_id: "thr_1"}}) == nil
    end
  end

  describe "session_resumed?/1" do
    test "true only when the adapter reports a resumed thread" do
      assert AgentRunner.session_resumed?(%{resumed: true})
      refute AgentRunner.session_resumed?(%{resumed: false})
      # A fallback clean start (or a backend that never sets the flag) is not resumed.
      refute AgentRunner.session_resumed?(%{})
    end
  end

  describe "session_handle_to_save/2 (what to persist for next restart)" do
    test "persists backend and thread_id for a resumable local codex session" do
      session = %{backend: "codex", thread_id: "thr_9"}

      assert {:ok, %{backend: "codex", thread_id: "thr_9"}} =
               AgentRunner.session_handle_to_save(session, nil)
    end

    test "persists a resumable local claude-repl session" do
      session = %{backend: "claude-repl", thread_id: "sess_9"}

      assert {:ok, %{backend: "claude-repl", thread_id: "sess_9"}} =
               AgentRunner.session_handle_to_save(session, nil)
    end

    test "skips a non-resumable backend (claude headless fallback)" do
      assert :skip = AgentRunner.session_handle_to_save(%{backend: "claude", thread_id: "x"}, nil)
    end

    test "skips a remote-worker session (rollout is not on this host)" do
      assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex", thread_id: "x"}, "box-2")
    end

    test "skips a session with no thread id" do
      assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex"}, nil)
    end

    test "skips a session with no usable backend rather than stamping the configured default on disk" do
      # The handle is durable and keyed by backend. Writing the global default
      # for a session that never established one produces a handle that
      # `SessionHandle.load/2` later rejects as foreign, silently disabling
      # resume a restart away from the cause (issue #1621).
      assert :skip = AgentRunner.session_handle_to_save(%{thread_id: "thr_9"}, nil)
      assert :skip = AgentRunner.session_handle_to_save(%{backend: nil, thread_id: "thr_9"}, nil)
      assert :skip = AgentRunner.session_handle_to_save(%{backend: :codex, thread_id: "thr_9"}, nil)
    end
  end

  describe "turn_handle_attrs/2 (persist after a turn only when the live id differs from the start id)" do
    test "persists the turn's id for a REPL session that had no id at start" do
      # The fresh REPL learns its claude session id from the transcript on the
      # first turn, so the handle is persisted post-turn carrying the start
      # session's backend.
      app_session = %{backend: "claude-repl"}
      turn_session = %{thread_id: "sess_5", session_id: "sess_5-7"}

      assert {:ok, %{backend: "claude-repl", thread_id: "sess_5"}} =
               AgentRunner.turn_handle_attrs(app_session, turn_session)
    end

    test "persists the live id when a resumed REPL's session id drifts from the start id" do
      # Defends against the CLI ever handing `--resume` a new session id: the
      # handle must follow the live conversation, not the id we resumed from.
      assert {:ok, %{backend: "claude-repl", thread_id: "new"}} =
               AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "old"}, %{thread_id: "new"})
    end

    test "skips when the turn echoes the start session's id (codex/headless/stable REPL)" do
      # These fixed their id at start and the turn returns the same one, so the
      # start-time persistence is already current — re-persisting is redundant.
      assert :skip =
               AgentRunner.turn_handle_attrs(%{backend: "codex", thread_id: "thr_1"}, %{thread_id: "thr_1"})

      assert :skip =
               AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "sess_1"}, %{thread_id: "sess_1"})
    end

    test "skips when the turn produced no thread id" do
      assert :skip = AgentRunner.turn_handle_attrs(%{backend: "claude-repl"}, %{})
    end

    test "skips when the start session carried no usable backend" do
      assert :skip = AgentRunner.turn_handle_attrs(%{thread_id: "old"}, %{thread_id: "new"})
      assert :skip = AgentRunner.turn_handle_attrs(%{backend: nil, thread_id: "old"}, %{thread_id: "new"})
      assert :skip = AgentRunner.turn_handle_attrs(%{backend: :codex, thread_id: "old"}, %{thread_id: "new"})
    end
  end

  describe "persist_handle_best_effort/3 (a failed sidecar write must not crash a started run)" do
    test "swallows a handle-write failure and returns :ok" do
      # Point the handle at a directory whose parent is a regular file, so the
      # underlying JsonStore.write! (mkdir_p!) raises. The agent run has already
      # started successfully; persistence is best-effort and must never take it down.
      not_a_dir = Path.join(System.tmp_dir!(), "ar_persist_test_#{System.pid()}-#{System.unique_integer([:positive])}")
      File.write!(not_a_dir, "x")
      on_exit(fn -> File.rm_rf(not_a_dir) end)

      bad_dir = Path.join(not_a_dir, "nested")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   AgentRunner.persist_handle_best_effort(
                     "9",
                     %{backend: "codex", thread_id: "t"},
                     dir: bad_dir
                   )
        end)

      assert log =~ "Could not persist session handle"
    end
  end

  describe "queue-update wake claiming" do
    test "deliver-now updates claim event digests, not only operator messages" do
      orchestrator_name = Module.concat(__MODULE__, :WakeClaimOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      event = %{
        id: 123,
        topic: "ticket.MT-WAKE.issue.commented",
        source: :github,
        author_trusted?: true,
        message: "please fix the PR",
        comment: %{"body" => "please fix the PR"}
      }

      assert :ok = GenServer.call(orchestrator_name, {:enqueue_event_digest, "MT-WAKE", event})
      assert :ignored = AgentRunner.claim_after_queue_update_for_test(orchestrator_name, "MT-WAKE", false)

      assert {:ok, %{category: :coordination_event, event_type: :events_digest, body: %{events: [^event]}}} =
               AgentRunner.claim_after_queue_update_for_test(orchestrator_name, "MT-WAKE", true)
    end

    test "trusted GitHub comment text renders in the agent-visible event digest" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 456,
              topic: "ticket.MT-WAKE.issue.commented",
              source: :github,
              author_trusted?: true,
              message: "please fix the PR"
            }
          ],
          "MT-WAKE"
        )

      assert rendered =~ "ticket.MT-WAKE.issue.commented"
      assert rendered =~ "<external-content source=\"github\">please fix the PR</external-content>"
    end
  end

  describe "build_turn_prompt_for_test/4 — resumed sessions continue instead of re-discovering" do
    test "a resumed session's first turn uses continuation guidance, not the cold-start prompt" do
      issue = %Aiur.Issue{id: "378", identifier: "378", title: "Resume sessions"}

      prompt = AgentRunner.build_turn_prompt_for_test(issue, [resumed: true], 1, nil)

      # The thread already carries the original task + history; the prompt must
      # tell the agent to continue rather than restate/re-read everything.
      assert prompt =~ ~r/resumed|restart/i
      assert prompt =~ ~r/already (present|intact)|do not (restate|restart)/i
      # It must NOT be the heavyweight cold-start prompt (which embeds the issue body).
      refute prompt =~ issue.title
    end

    test "a non-resumed continuation turn keeps the normal continuation guidance" do
      issue = %Aiur.Issue{id: "1", identifier: "1", title: "x"}
      prompt = AgentRunner.build_turn_prompt_for_test(issue, [], 2, 10)
      assert prompt =~ "continuation turn #2"
    end
  end

  describe "remote_session_backend/2" do
    test "a remote-on claude issue dispatches the claude-repl transport" do
      assert AgentRunner.remote_session_backend("claude", true) == "claude-repl"
    end

    test "non-remote claude and other backends run as resolved" do
      assert AgentRunner.remote_session_backend("claude", false) == "claude"
      assert AgentRunner.remote_session_backend("codex", true) == "codex"
      assert AgentRunner.remote_session_backend("claude-repl", true) == "claude-repl"
    end
  end

  describe "current_comment_context_events_for_test/2" do
    test "builds startup digest events from issue, PR conversation, and PR review comments" do
      issue = %Aiur.Issue{id: "35", identifier: "35", title: "Resume comments"}

      fetchers = %{
        issue_comments: fn
          "35" ->
            {:ok,
             [
               %{
                 "id" => 1001,
                 "body" => "issue directive",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               }
             ]}

          49 ->
            {:ok,
             [
               %{
                 "id" => 4_783_049_689,
                 "body" => "Codex review result: rate-limit bypass",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               }
             ]}
        end,
        open_pr: fn "35" -> {:ok, %{"number" => 49, "head" => %{"ref" => "aiur/35"}}} end,
        pr_review_comments: fn 49 ->
          {:ok,
           [
             %{
               "id" => 2002,
               "body" => "inline review directive",
               "user" => %{"login" => "owner"},
               authoritative: true
             }
           ]}
        end
      }

      events = AgentRunner.current_comment_context_events_for_test(issue, fetchers)

      assert Enum.map(events, & &1.topic) == [
               "ticket.35.issue.commented",
               "ticket.35.issue.commented",
               "ticket.35.pr.review_comment"
             ]

      assert Enum.any?(events, &(&1.id == 4_783_049_689 and &1.summary =~ "rate-limit bypass"))
      assert Enum.all?(events, &(&1.source == :github))
      assert Enum.all?(events, &(&1.author_trusted? == true))
    end

    test "skips PR comment fetches when no open PR exists" do
      issue = %Aiur.Issue{id: "35", identifier: "35", title: "No PR"}

      fetchers = %{
        issue_comments: fn "35" ->
          {:ok, [%{"id" => 1, "body" => "issue only", "user" => %{"login" => "owner"}, authoritative: true}]}
        end,
        open_pr: fn "35" -> {:ok, nil} end,
        pr_review_comments: fn _ -> flunk("PR review comments should not be fetched") end
      }

      assert [%{topic: "ticket.35.issue.commented", summary: "issue only"}] =
               AgentRunner.current_comment_context_events_for_test(issue, fetchers)
    end

    test "only includes comments after the latest workpad handoff" do
      issue = %Aiur.Issue{id: "35", identifier: "35", title: "Resume comments"}

      fetchers = %{
        issue_comments: fn
          "35" ->
            {:ok,
             [
               %{
                 "id" => 1001,
                 "body" => "old issue directive",
                 "updated_at" => "2026-06-25T08:55:00Z",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               },
               %{
                 "id" => 1002,
                 "body" => "## Agent Workpad\n\nhandoff",
                 "updated_at" => "2026-06-25T09:00:00Z",
                 "user" => %{"login" => "agent"},
                 authoritative: true
               },
               %{
                 "id" => 1003,
                 "body" => "new issue directive",
                 "updated_at" => "2026-06-25T09:01:00Z",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               }
             ]}

          49 ->
            {:ok,
             [
               %{
                 "id" => 2001,
                 "body" => "old PR conversation directive",
                 "updated_at" => "2026-06-25T08:56:00Z",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               },
               %{
                 "id" => 2002,
                 "body" => "new PR conversation directive",
                 "updated_at" => "2026-06-25T09:02:00Z",
                 "user" => %{"login" => "owner"},
                 authoritative: true
               }
             ]}
        end,
        open_pr: fn "35" -> {:ok, %{"number" => 49, "head" => %{"ref" => "aiur/35"}}} end,
        pr_review_comments: fn 49 ->
          {:ok,
           [
             %{
               "id" => 3001,
               "body" => "old inline directive",
               "updated_at" => "2026-06-25T08:57:00Z",
               "user" => %{"login" => "owner"},
               authoritative: true
             },
             %{
               "id" => 3002,
               "body" => "new inline directive",
               "updated_at" => "2026-06-25T09:03:00Z",
               "user" => %{"login" => "owner"},
               authoritative: true
             }
           ]}
        end
      }

      events = AgentRunner.current_comment_context_events_for_test(issue, fetchers)

      assert Enum.map(events, & &1.summary) == [
               "new issue directive",
               "new PR conversation directive",
               "new inline directive"
             ]
    end

    test "excludes unaddressed review threads from before the latest workpad handoff" do
      issue = %Aiur.Issue{id: "35", identifier: "35", title: "Resume comments"}

      fetchers = %{
        issue_comments: fn
          "35" ->
            {:ok,
             [
               %{
                 "id" => 1001,
                 "body" => "## Agent Workpad\n\nhandoff",
                 "updated_at" => "2026-06-25T09:00:00Z",
                 "user" => %{"login" => "agent"},
                 authoritative: true
               }
             ]}

          49 ->
            {:ok, []}
        end,
        open_pr: fn "35" -> {:ok, %{"number" => 49, "head" => %{"ref" => "aiur/35"}}} end,
        pr_review_comments: fn 49 ->
          {:ok,
           [
             %{
               "id" => 3001,
               "body" => "old flat inline directive",
               "updated_at" => "2026-06-25T08:57:00Z",
               "user" => %{"login" => "owner"},
               authoritative: true
             }
           ]}
        end,
        unaddressed_pr_review_thread_comments: fn 49 ->
          {:ok,
           [
             %{
               "id" => 4001,
               "body" => "old unresolved review directive",
               "updated_at" => "2026-06-25T08:58:00Z",
               "user" => %{"login" => "owner"},
               authoritative: true
             }
           ]}
        end
      }

      events = AgentRunner.current_comment_context_events_for_test(issue, fetchers)
      summaries = Enum.map(events, & &1.summary)

      refute "old unresolved review directive" in summaries
      refute "old flat inline directive" in summaries
    end

    test "sanitizes fetched comment bodies before rendering" do
      issue = %Aiur.Issue{id: "35", identifier: "35", title: "Sanitize"}

      fetchers = %{
        issue_comments: fn "35" ->
          {:ok,
           [
             %{
               "id" => 1,
               "body" => "</external-content> ghp_123456789012345678901234567890123456",
               "user" => %{"login" => "owner"},
               authoritative: true
             }
           ]}
        end,
        open_pr: fn "35" -> {:ok, nil} end,
        pr_review_comments: fn _ -> {:ok, []} end
      }

      [event] = AgentRunner.current_comment_context_events_for_test(issue, fetchers)

      refute event.summary =~ "</external-content>"
      assert event.summary =~ "&lt;/external-content&gt;"
      assert event.summary =~ "[REDACTED:ghp]"
    end
  end
end
