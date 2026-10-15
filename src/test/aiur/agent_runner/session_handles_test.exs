defmodule Aiur.AgentRunner.SessionHandlesTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner

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
      not_a_dir = Aiur.TestSupport.tmp_root!("ar_persist_test")
      File.write!(not_a_dir, "x")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(not_a_dir) end)

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
end
