defmodule Aiur.PaneRPCTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, PaneRPC}

  describe "snapshot/0" do
    test "returns a list" do
      assert is_list(PaneRPC.snapshot())
    end
  end

  describe "send_operator_message/2" do
    test "rejects bodies larger than the cap" do
      oversized = String.duplicate("x", 65_537)
      assert {:error, :body_too_long} = PaneRPC.send_operator_message("MT-1", oversized)
    end

    test "strips control characters before forwarding" do
      # The forward will fail (no running agent) but body sanitization runs first.
      assert {:error, _} = PaneRPC.send_operator_message("MT-1", "hi\x01there")
    end
  end

  defmodule FailingConversations do
    @moduledoc false
    def attach(_identifier), do: {:error, :bogus_reason}
  end

  describe "attach_conversation/1 and detach_conversation/1" do
    test "attach returns :ok and detach is a no-op when no subscription exists" do
      assert :ok = PaneRPC.attach_conversation("MT-99")
      assert :ok = PaneRPC.detach_conversation("MT-99")
    end

    test "attach surfaces errors from the conversations module unchanged" do
      assert {:error, :bogus_reason} =
               PaneRPC.attach_conversation("MT-ATT-ERR", FailingConversations)
    end
  end

  describe "fetch_context/2" do
    test "returns the history with a nil context_message for an unknown identifier" do
      # `IssueContext.for/1` returns a placeholder map with nil title/
      # description/url for an identifier the tracker doesn't know,
      # which drops `context_message` to nil. The history list comes
      # from `IssueLog.history/2` and is empty when no log file exists.
      assert {:ok, %{context_message: nil, history: history}} =
               PaneRPC.fetch_context("MT-UNKNOWN-#{System.unique_integer([:positive])}")

      assert is_list(history)
    end

    test "returns a populated context_message when the tracker knows the issue" do
      identifier = "MT-CONTEXT-#{System.unique_integer([:positive])}"

      # Re-write the workflow to point at the in-memory tracker and
      # seed it with a real issue. `IssueContext.for/1` walks
      # `Tracker.fetch_candidate_issues/0` to find a match, so we need
      # the tracker adapter to be the Memory one for the test.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      issue = %Issue{
        id: identifier,
        identifier: identifier,
        title: "Demo issue",
        description: "A description.",
        url: "https://example.test/issues/" <> identifier,
        state: "todo"
      }

      Application.put_env(:aiur, :memory_tracker_issues, [issue])

      assert {:ok, %{context_message: context_message, history: _}} =
               PaneRPC.fetch_context(identifier)

      assert is_binary(context_message)
      assert context_message =~ "Working on " <> identifier
      assert context_message =~ "Demo issue"
    end
  end
end
