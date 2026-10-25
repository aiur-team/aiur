defmodule Aiur.AgentRunner.SessionResumeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.SessionResume
  alias Aiur.SessionHandle

  describe "resume_thread_id/3" do
    test "returns the id only for a local resumable backend with a valid handle" do
      assert SessionResume.resume_thread_id("codex", nil, {:ok, %{thread_id: "thr_1"}}) == "thr_1"
      assert SessionResume.resume_thread_id("claude-repl", nil, {:ok, %{thread_id: "sess_1"}}) == "sess_1"
      assert SessionResume.resume_thread_id("muse", nil, {:ok, %{thread_id: "native-session"}}) == "native-session"
      assert SessionResume.resume_thread_id("muse", "other-host", {:ok, %{thread_id: "native-session"}}) == nil

      assert SessionResume.resume_thread_id("codex", "box-2", {:ok, %{thread_id: "thr_1"}}) == nil
      assert SessionResume.resume_thread_id("codex", nil, :none) == nil
      assert SessionResume.resume_thread_id("claude", nil, {:ok, %{thread_id: "thr_1"}}) == nil
    end
  end

  describe "session_resumed?/1" do
    test "is true only when the adapter reports a resumed thread" do
      assert SessionResume.session_resumed?(%{resumed: true})
      refute SessionResume.session_resumed?(%{resumed: false})
      refute SessionResume.session_resumed?(%{})
    end
  end

  describe "turn_handle_attrs/2" do
    test "returns attrs only when the turn has a binary thread id drift" do
      assert {:ok, %{backend: "claude-repl", thread_id: "new"}} =
               SessionResume.turn_handle_attrs(%{backend: "claude-repl", thread_id: "old"}, %{thread_id: "new"})

      assert :skip =
               SessionResume.turn_handle_attrs(%{backend: "codex", thread_id: "same"}, %{thread_id: "same"})

      assert :skip = SessionResume.turn_handle_attrs(%{backend: "claude-repl"}, %{})
      assert :skip = SessionResume.turn_handle_attrs(%{backend: "claude-repl"}, %{thread_id: 123})
    end
  end

  describe "session_handle_to_save/2" do
    test "gates persistence on local host, resumable backend, and binary thread id" do
      assert {:ok, %{backend: "codex", thread_id: "thr_9"}} =
               SessionResume.session_handle_to_save(%{backend: "codex", thread_id: "thr_9"}, nil)

      assert {:ok, %{backend: "claude-repl", thread_id: "sess_9"}} =
               SessionResume.session_handle_to_save(%{backend: "claude-repl", thread_id: "sess_9"}, nil)

      assert {:ok, %{backend: "muse", thread_id: "native-session"}} =
               SessionResume.session_handle_to_save(%{backend: "muse", thread_id: "native-session"}, nil)

      assert :skip = SessionResume.session_handle_to_save(%{backend: "codex", thread_id: "thr_9"}, "box-2")
      assert :skip = SessionResume.session_handle_to_save(%{backend: "claude", thread_id: "thr_9"}, nil)
      assert :skip = SessionResume.session_handle_to_save(%{backend: "codex"}, nil)
    end
  end

  describe "track_resume_turn_start/4" do
    setup do
      dir = Aiur.TestSupport.tmp_root!("aiur_session_resume_port_closed")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
      opts = [dir: dir, hostname: "h", repo_name: "resume-test"]
      :ok = SessionHandle.save("4561", %{backend: "codex", thread_id: "big"}, opts)
      %{opts: opts}
    end

    @port_closed {:error, {:turn_start_failed, :port_closed}}

    test "drops the resumed thread after two consecutive port_closed turn starts", %{opts: opts} do
      resumed = %{resumed: true, thread_id: "big"}

      assert SessionResume.track_resume_turn_start(resumed, "4561", @port_closed, opts) == @port_closed
      assert {:ok, %{thread_id: "big"}} = SessionHandle.load("4561", "codex", opts)

      capture_log(fn ->
        assert SessionResume.track_resume_turn_start(resumed, "4561", @port_closed, opts) == @port_closed
      end)

      assert SessionHandle.load("4561", "codex", opts) == :none

      # The fresh session's handle resumes normally afterwards.
      :ok = SessionHandle.save("4561", %{backend: "codex", thread_id: "fresh"}, opts)
      assert {:ok, %{thread_id: "fresh"}} = SessionHandle.load("4561", "codex", opts)
    end

    test "a resumed turn that gets past start resets the count", %{opts: opts} do
      resumed = %{resumed: true, thread_id: "big"}

      SessionResume.track_resume_turn_start(resumed, "4561", @port_closed, opts)
      SessionResume.track_resume_turn_start(resumed, "4561", {:ok, %{}}, opts)
      SessionResume.track_resume_turn_start(resumed, "4561", @port_closed, opts)

      assert {:ok, %{thread_id: "big"}} = SessionHandle.load("4561", "codex", opts)
    end

    test "fresh sessions and other failures never drop the thread", %{opts: opts} do
      fresh = %{resumed: false, thread_id: "big"}
      resumed = %{resumed: true, thread_id: "big"}

      for _ <- 1..3, do: SessionResume.track_resume_turn_start(fresh, "4561", @port_closed, opts)
      for _ <- 1..3, do: SessionResume.track_resume_turn_start(resumed, "4561", {:error, {:turn_start_failed, :response_timeout}}, opts)

      assert {:ok, %{thread_id: "big"}} = SessionHandle.load("4561", "codex", opts)
    end

    test "the fresh session after a drop gets continuation prompt opts", %{opts: opts} do
      resumed = %{resumed: true, thread_id: "big"}
      fresh = %{resumed: false, thread_id: "fresh"}

      assert SessionResume.put_first_turn_opts([], fresh, "4561", opts) == [resumed: false]

      capture_log(fn ->
        for _ <- 1..2, do: SessionResume.track_resume_turn_start(resumed, "4561", @port_closed, opts)
      end)

      first_turn_opts = SessionResume.put_first_turn_opts([], fresh, "4561", opts)
      assert first_turn_opts[:prior_work] and first_turn_opts[:abandoned_thread]
      assert SessionResume.put_first_turn_opts([], resumed, "4561", opts) == [resumed: true]
    end

    test "a completed fresh session clears the abandoned marker", %{opts: opts} do
      SessionHandle.drop_thread("4561", opts)
      assert SessionHandle.abandoned_thread?("4561", opts)

      assert :ok = SessionResume.fresh_turn_completed(%{resumed: false}, "4561", opts)
      refute SessionHandle.abandoned_thread?("4561", opts)
    end

    test "a completed resumed session preserves the abandoned marker", %{opts: opts} do
      SessionHandle.drop_thread("4561", opts)

      assert :ok = SessionResume.fresh_turn_completed(%{resumed: true}, "4561", opts)
      assert SessionHandle.abandoned_thread?("4561", opts)
    end
  end

  describe "persist_handle_best_effort/3" do
    test "returns :ok for a valid handle write" do
      dir = Aiur.TestSupport.tmp_root!("aiur_session_resume_test")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

      assert :ok =
               SessionResume.persist_handle_best_effort("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h")

      assert {:ok, %{thread_id: "t"}} = SessionHandle.load("9", "codex", dir: dir, hostname: "h")
    end

    test "swallows a raised handle write" do
      not_a_dir = Aiur.TestSupport.tmp_root!("aiur_session_resume_raise")
      File.write!(not_a_dir, "x")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(not_a_dir) end)

      log =
        capture_log(fn ->
          assert :ok =
                   SessionResume.persist_handle_best_effort(
                     "9",
                     %{backend: "codex", thread_id: "t"},
                     dir: Path.join(not_a_dir, "nested")
                   )
        end)

      assert log =~ "Could not persist session handle"
    end
  end
end
