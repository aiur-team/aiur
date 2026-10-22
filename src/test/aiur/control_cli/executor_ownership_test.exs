defmodule Aiur.ControlCLI.ExecutorOwnershipTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  setup do
    :ok = write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  test "the owner passed by the invoking CLI wins and release removes only its own marker" do
    issue = %Issue{
      id: "5077",
      identifier: "5077",
      title: "Executor work",
      state: "todo",
      labels: []
    }

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    output = capture_io(fn -> AgentControlCLI.take(["5077"], "cli-owner") end)
    assert output =~ "ticket #5077 held by cli-owner"
    assert_received {:memory_tracker_ensure_labels, ["agent:executor:cli-owner"]}
    assert_received {:memory_tracker_add_label, "5077", "agent:executor:cli-owner"}

    Application.put_env(:aiur, :memory_tracker_issues, [
      %{issue | labels: ["agent:executor:cli-owner"]}
    ])

    refused =
      capture_io(fn ->
        capture_io(:stderr, fn -> AgentControlCLI.release(["5077"], "other") end)
      end)

    assert refused =~ "owned by another Executor"

    released = capture_io(fn -> AgentControlCLI.release(["5077"], "cli-owner") end)
    assert released =~ "Executor hold released for #5077"
    assert_received {:memory_tracker_remove_label, "5077", "agent:executor:cli-owner"}
  end

  test "take refuses a ticket already held by another Executor" do
    issue = %Issue{
      id: "5077",
      identifier: "5077",
      title: "Executor work",
      state: "todo",
      labels: ["agent:executor:alice"]
    }

    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    output = capture_io(fn -> AgentControlCLI.take(["5077"], "bob") end)

    assert output =~ "owned by another Executor"
    refute_received {:memory_tracker_add_label, "5077", "agent:executor:bob"}
    refute_received {:memory_tracker_remove_label, "5077", "agent:executor:alice"}
  end
end
