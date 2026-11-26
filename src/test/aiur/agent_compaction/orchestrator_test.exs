defmodule Aiur.AgentCompaction.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentCompaction.Config, as: CompactionConfig
  alias Aiur.AgentCompaction.Orchestrator
  alias Aiur.Config.Schema.Compaction

  test "unsupported provider is rejected even when global opt-in is off" do
    refute Orchestrator.supported_backend?("claude")
    refute Orchestrator.supported_backend?("muse")
  end

  test "a live Codex port is required to compact" do
    assert {:error, "failed to submit compaction request: live Codex session is unavailable"} =
             Orchestrator.trigger_compaction(%{thread_id: "thread", id: "ticket"}, "codex", 4)
  end

  test "manual terminal-handoff opt-in requires all three actual settings" do
    refute CompactionConfig.should_compact_at_handoff?(%Compaction{enabled: false, manual_approval: true, backends: ["codex"]}, nil)
    refute CompactionConfig.should_compact_at_handoff?(%Compaction{enabled: true, manual_approval: false, backends: ["codex"]}, nil)
    refute CompactionConfig.should_compact_at_handoff?(%Compaction{enabled: true, manual_approval: true, backends: []}, nil)
    assert CompactionConfig.should_compact_at_handoff?(%Compaction{enabled: true, manual_approval: true, backends: ["codex"]}, nil)
  end

  test "threshold opt-in only fires at or above the configured cumulative usage" do
    config = %Compaction{enabled: true, backends: ["codex"], auto_trigger: %Compaction.AutoTrigger{enabled: true, token_threshold: 50_000}}

    refute CompactionConfig.should_compact_at_handoff?(config, nil)
    refute CompactionConfig.should_compact_at_handoff?(config, 49_999)
    assert CompactionConfig.should_compact_at_handoff?(config, 50_000)
    assert CompactionConfig.should_compact_at_handoff?(config, 75_000)
  end

  test "already compacted sessions are explicitly skipped when enabled" do
    assert Orchestrator.already_compacted?(%{compacted_at: "2026-10-06T00:00:00Z"})
    refute Orchestrator.already_compacted?(%{compacted_at: nil})
    refute Orchestrator.already_compacted?(%{})
  end

  test "durable outcomes suppress another attempt on the same unchanged thread" do
    assert Orchestrator.already_attempted_for_thread?(%{"thread_id" => "thread-1", "status" => "completed"}, "thread-1")
    assert Orchestrator.already_attempted_for_thread?(%{"thread_id" => "thread-1", "status" => "failed"}, "thread-1")
    assert Orchestrator.already_attempted_for_thread?(%{"thread_id" => "thread-1", "status" => "unsupported"}, "thread-1")
    refute Orchestrator.already_attempted_for_thread?(%{"thread_id" => "thread-1", "status" => "completed"}, "thread-2")
    assert Orchestrator.already_attempted_for_thread?(%{"thread_id" => "thread-1", "status" => "pending"}, "thread-1")
  end

  test "a pending attempt found after restart becomes a durable failure without retrying" do
    pending = %{"thread_id" => "thread-1", "status" => "pending"}
    recovered = Orchestrator.interrupted_pending_attempt(pending, "thread-1")

    assert recovered == %{
             "thread_id" => "thread-1",
             "status" => "failed",
             "reason" => "interrupted before completion; not retried"
           }

    assert Orchestrator.already_attempted_for_thread?(recovered, "thread-1")
  end

  test "a pending attempt for a different thread is left unchanged" do
    pending = %{"thread_id" => "thread-1", "status" => "pending"}
    assert Orchestrator.interrupted_pending_attempt(pending, "thread-2") == pending
  end
end
