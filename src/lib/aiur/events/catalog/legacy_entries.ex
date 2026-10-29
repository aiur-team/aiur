defmodule Aiur.Events.Catalog.LegacyEntries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.Entry

  @alerts [
    # aiur/agent_compaction/handoff.ex
    {"compaction.*", "agent-runner"},
    # aiur/config/overrides.ex
    {"config.override_rejected", "config"},
    # aiur/decision_store/persistence.ex
    {"decision_store.append_ambiguous", "commands"},
    # aiur/decision_store/boot.ex
    {"decision_store.corrupted", "commands"},
    # aiur/decision_store/projection_recovery.ex
    {"decision_store.repair_failed", "commands"},
    # aiur/decision_store/boot.ex
    {"decision_store.unrecognized_event_types", "commands"},
    # aiur/executor_listener.ex
    {"executor.bindings.incomplete", "executor-attention"},
    # aiur/executor_listener.ex
    {"executor.bindings.incomplete.resolved", "executor-attention"},
    # aiur/executor_listener.ex
    {"executor.command.*", "executor-attention"},
    # aiur/operator_relay.ex
    {"executor.command.operator_relayed", "commands"},
    # aiur/executor_wake_inbox/recovery.ex
    {"executor.wakes.flush_failing", "executor-attention"},
    # aiur/executor_wake_inbox/recovery.ex
    {"executor.wakes.journal_quarantined", "executor-attention"},
    # aiur/executor_wake_inbox/storage.ex
    {"executor.wakes.overflow", "executor-attention"},
    # aiur/executor_wake_inbox/recovery.ex
    {"executor.wakes.trim_failed", "executor-attention"},
    # aiur/executor_events.ex
    {"executor_events.corrupted", "executor-attention"},
    # aiur/github/dispatch_authorization.ex
    {"github.dispatch_authorization.ambiguous", "github"},
    # aiur/github/dispatch_authorization.ex
    {"github.dispatch_authorization.timeline_unreadable", "github"},
    # aiur/orchestrator/retry_engine/poll_failure.ex
    {"orchestrator.claim_released", "orchestration"}
  ]

  @entries Enum.map(@alerts, fn {pattern, owner} -> %Entry{pattern: pattern, class: :ledgered, owner: owner} end)

  @spec entries() :: [Entry.t()]
  def entries, do: @entries
end
