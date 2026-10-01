defmodule Aiur.AgentCompaction.CodexClientTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentCompaction.CodexClient

  describe "request_compact/3" do
    test "returns ok with request_id for valid inputs" do
      {:ok, request_id} = CodexClient.request_compact("thread-123", "summarize this")

      assert is_binary(request_id)
      assert String.starts_with?(request_id, "req_")
    end

    test "returns error for empty thread_id" do
      {:error, msg} = CodexClient.request_compact("", "summarize this")

      assert String.contains?(msg, "thread_id")
    end

    test "returns error for empty summary_prompt" do
      {:error, msg} = CodexClient.request_compact("thread-123", "")

      assert String.contains?(msg, "summary_prompt")
    end
  end

  describe "poll_status/3" do
    test "returns ok with pending status" do
      {:ok, status} = CodexClient.poll_status("thread-123", "req-123")

      assert status == :pending
    end
  end

  describe "wait_for_completion/3" do
    test "returns timeout for mock implementation" do
      result = CodexClient.wait_for_completion("thread-123", "req-123", 100)

      assert result == {:timeout}
    end
  end

  describe "validate_summary/1" do
    test "accepts valid summary with all required sections" do
      summary = %{
        "task_constraints" => "Do X with Y",
        "decisions" => "Chose approach A",
        "revision_history" => "Changed file.ex",
        "validation_evidence" => "All tests pass",
        "review_work" => "Check error handling"
      }

      {:ok, validated} = CodexClient.validate_summary(summary)

      assert validated == summary
    end

    test "rejects summary with missing sections" do
      summary = %{
        "task_constraints" => "Do X with Y",
        "decisions" => "Chose approach A"
      }

      {:error, msg} = CodexClient.validate_summary(summary)

      assert String.contains?(msg, "missing required sections")
    end

    test "rejects non-map input" do
      {:error, msg} = CodexClient.validate_summary("not a map")

      assert String.contains?(msg, "must be a map")
    end

    test "rejects summary with empty task_constraints" do
      summary = %{
        "task_constraints" => "",
        "decisions" => "Chose approach A",
        "revision_history" => "Changed file.ex",
        "validation_evidence" => "All tests pass",
        "review_work" => "Check error handling"
      }

      {:error, msg} = CodexClient.validate_summary(summary)

      assert String.contains?(msg, "cannot be empty")
    end
  end
end
