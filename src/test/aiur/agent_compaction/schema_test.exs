defmodule Aiur.AgentCompaction.SchemaTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentCompaction.Schema

  describe "new/3" do
    test "creates a pending compaction state with defaults" do
      state = Schema.new("session-123", "codex", :manual)

      assert state.session_id == "session-123"
      assert state.backend == "codex"
      assert state.trigger_type == :manual
      assert state.status == :pending
      assert is_nil(state.completed_at)
      assert is_nil(state.error_reason)
    end
  end

  describe "mark_completed/4" do
    test "marks state as completed with durable transcript references" do
      state = Schema.new("session-123", "codex", :manual)

      completed =
        Schema.mark_completed(
          state,
          "compacted_ref_123",
          "original_ref_123",
          4_500
        )

      assert completed.status == :completed
      assert completed.compacted_transcript_ref == "compacted_ref_123"
      assert completed.original_transcript_ref == "original_ref_123"
      assert completed.summary_tokens == 4_500
      assert not is_nil(completed.completed_at)
    end
  end

  describe "mark_failed/2" do
    test "marks state as failed with error reason" do
      state = Schema.new("session-123", "codex", :manual)

      failed = Schema.mark_failed(state, "API timeout")

      assert failed.status == :failed
      assert failed.error_reason == "API timeout"
      assert not is_nil(failed.completed_at)
    end
  end

  describe "validate/1" do
    test "accepts valid compaction state" do
      state = Schema.new("session-123", "codex", :manual)

      {:ok, validated} = Schema.validate(state)
      assert validated.session_id == "session-123"
    end

    test "rejects missing session_id" do
      state = %{
        backend: "codex",
        trigger_type: :manual,
        status: :pending,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      {:error, msg} = Schema.validate(state)
      assert String.contains?(msg, "session_id")
    end

    test "rejects an unknown trigger value" do
      state = Schema.new("session-123", "codex", :manual) |> Map.put(:trigger_type, :auto_threshold)
      assert {:ok, _} = Schema.validate(state)
      state = Map.put(state, :trigger_type, :heuristic)
      assert {:error, "trigger_type must be :manual or :auto_threshold"} = Schema.validate(state)
    end
  end

  describe "unchanged_since_last_compaction?/2" do
    test "returns true when message count is unchanged" do
      state = %{message_count_at_compaction: 42}

      assert Schema.unchanged_since_last_compaction?(state, 42)
    end

    test "returns false when message count increased" do
      state = %{message_count_at_compaction: 42}

      refute Schema.unchanged_since_last_compaction?(state, 43)
    end

    test "returns false when no prior compaction count" do
      state = %{}

      refute Schema.unchanged_since_last_compaction?(state, 42)
    end
  end
end
