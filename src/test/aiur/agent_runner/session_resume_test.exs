defmodule Aiur.AgentRunner.SessionResumeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.SessionResume
  alias Aiur.SessionHandle

  describe "resume_thread_id/3" do
    test "returns the id only for a local resumable backend with a valid handle" do
      assert SessionResume.resume_thread_id("codex", nil, {:ok, %{thread_id: "thr_1"}}) == "thr_1"
      assert SessionResume.resume_thread_id("claude-repl", nil, {:ok, %{thread_id: "sess_1"}}) == "sess_1"

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

      assert :skip = SessionResume.session_handle_to_save(%{backend: "codex", thread_id: "thr_9"}, "box-2")
      assert :skip = SessionResume.session_handle_to_save(%{backend: "claude", thread_id: "thr_9"}, nil)
      assert :skip = SessionResume.session_handle_to_save(%{backend: "codex"}, nil)
    end
  end

  describe "persist_handle_best_effort/3" do
    test "returns :ok for a valid handle write" do
      dir = Path.join(System.tmp_dir!(), "aiur_session_resume_test_#{System.pid()}-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok =
               SessionResume.persist_handle_best_effort("9", %{backend: "codex", thread_id: "t"}, dir: dir, hostname: "h")

      assert {:ok, %{thread_id: "t"}} = SessionHandle.load("9", "codex", dir: dir, hostname: "h")
    end

    test "swallows a raised handle write" do
      not_a_dir = Path.join(System.tmp_dir!(), "aiur_session_resume_raise_#{System.pid()}-#{System.unique_integer([:positive])}")
      File.write!(not_a_dir, "x")
      on_exit(fn -> File.rm_rf(not_a_dir) end)

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
