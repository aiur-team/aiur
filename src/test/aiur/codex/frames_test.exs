defmodule Aiur.Codex.FramesTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Frames

  @policies %{approval_policy: "never", thread_sandbox: "read-only"}

  test "thread ids are fixed" do
    assert Frames.thread_start_id() == 2
    assert Frames.turn_start_id() == 3
  end

  test "thread/start includes dynamicTools and request id 2" do
    frame = Frames.thread_init_frame(nil, "/ws", @policies)

    assert frame["method"] == "thread/start"
    assert frame["id"] == 2
    assert frame["params"]["cwd"] == "/ws"
    assert frame["params"]["approvalPolicy"] == "never"
    assert frame["params"]["sandbox"] == "read-only"
    assert is_list(frame["params"]["dynamicTools"])
  end

  test "thread/resume excludes dynamicTools and uses request id 2" do
    frame = Frames.thread_init_frame("thr_1", "/ws", @policies)

    assert frame["method"] == "thread/resume"
    assert frame["id"] == 2
    assert frame["params"]["threadId"] == "thr_1"
    refute Map.has_key?(frame["params"], "dynamicTools")
  end

  test "turn_start_frame/6 builds the first turn request" do
    issue = %{identifier: "AIUR-813", title: "Extract Codex modules"}
    frame = Frames.turn_start_frame("thr", "prompt", issue, "/ws", "never", %{"mode" => "read-only"})

    assert frame["method"] == "turn/start"
    assert frame["id"] == 3
    assert frame["params"]["threadId"] == "thr"
    assert frame["params"]["input"] == [%{"type" => "text", "text" => "prompt"}]
    assert frame["params"]["cwd"] == "/ws"
    assert frame["params"]["title"] == "AIUR-813: Extract Codex modules"
    assert frame["params"]["approvalPolicy"] == "never"
    assert frame["params"]["sandboxPolicy"] == %{"mode" => "read-only"}
  end

  test "operator_turn_frame/3 carries the caller request id and session policies" do
    session = %{
      thread_id: "thr",
      workspace: "/ws",
      approval_policy: "untrusted",
      turn_sandbox_policy: %{"mode" => "workspace-write"}
    }

    frame = Frames.operator_turn_frame(session, 123, "hello")

    assert frame["method"] == "turn/start"
    assert frame["id"] == 123
    assert frame["params"]["threadId"] == "thr"
    assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello"}]
    assert frame["params"]["cwd"] == "/ws"
    assert frame["params"]["approvalPolicy"] == "untrusted"
    assert frame["params"]["sandboxPolicy"] == %{"mode" => "workspace-write"}
  end
end
