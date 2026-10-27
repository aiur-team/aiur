defmodule Aiur.Events.Catalog.PlannedEntries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.Entry

  @queue_causes ~w(prerequisite_failed dependency_changed_after_start promoted_unauthorized write_failed merged_issue_open optimistic_blocker_failed
    inputs_unavailable store_unavailable focus_starved agent_error pr_closed_unmerged not_planned duplicate edge_removed paused parked todo churn merged)
  @listener_reasons ~w(no_turn_boundary steer_not_wired no_interrupt pull_tool_unavailable not_running harness_unknown pending_session_start)

  # contracts/command-request-and-resolution.md §8 (MP-E2): text remains sealed.
  @decision (for pattern <- ["ticket.*.agent.decision.human-needed", "executor.decision.human-needed"] do
               %Entry{
                 pattern: pattern,
                 class: :journaled,
                 export?: true,
                 refs: if(String.starts_with?(pattern, "ticket."), do: [:ticket, :decision_id, :decision_version], else: [:decision_id, :decision_version]),
                 attrs: [
                   requester_kind: {:enum, ~w(worker executor)},
                   blocking: :boolean,
                   urgency: {:enum, ~w(low normal high critical)},
                   cause:
                     {:enum, ~w(executor_originated executor_offline executor_stalled authority_human_required executor_not_answerable executor_ack_timeout executor_answer_timeout executor_escalated)}
                 ],
                 owner: "commands"
               }
             end)

  # contracts/queue-readiness-and-build-progress.md §4.3 (MP-E1).
  @queue_events (for verb <- ~w(promoted withdrawn held released overridden removed) do
                   %Entry{pattern: "ticket.*.queue.#{verb}", class: :live, export?: true, refs: [:ticket, :queue_id], attrs: [cause: {:enum, @queue_causes}], owner: "build-queue"}
                 end)

  @queue [
    %Entry{pattern: "ticket.*.issue.closed", class: :live, export?: true, refs: [:ticket, :pr_number], reserved: true, owner: "github-listeners"},
    %Entry{pattern: "ticket.*.pr.closed_unmerged", class: :live, export?: true, refs: [:ticket, :pr_number], owner: "github-listeners"},
    %Entry{pattern: "ticket.*.queue.#", class: :live, export?: true, refs: [:ticket, :queue_id], attrs: [cause: {:enum, @queue_causes}], owner: "build-queue"},
    %Entry{
      pattern: "ticket.*.queue.attention.#",
      class: :ledgered,
      export?: true,
      refs: [:ticket, :prerequisite, :blocked],
      attrs: [cause: {:enum, @queue_causes}, blocked: {:list, :id}],
      owner: "build-queue"
    },
    %Entry{
      pattern: "system.queue.*.progress",
      class: :ledgered,
      export?: true,
      refs: [:queue_id],
      attrs: [milestone: {:enum, ~w(25 50 75 100)}, percent: :integer, generation: :integer, freshness: {:enum, ~w(current stale unknown unavailable)}],
      owner: "build-orders"
    },
    %Entry{pattern: "system.queue.attention.#", class: :ledgered, export?: true, attrs: [cause: {:enum, @queue_causes}], owner: "build-queue"},
    %Entry{
      pattern: "system.build_order.*.progress",
      class: :ledgered,
      export?: true,
      refs: [:root],
      attrs: [milestone: {:enum, ~w(25 50 75 100)}, percent: :integer, generation: :integer, freshness: {:enum, ~w(current stale unknown unavailable)}],
      owner: "build-orders"
    }
  ]

  # contracts/listener-mode.md §5 (MP-E7); actor is identity, never a feed attr.
  @listener [
    %Entry{
      pattern: "ticket.*.agent.listen-mode.changed",
      class: :live,
      export?: true,
      attrs: [requested: {:enum, ~w(steer sync async)}, effective: {:enum, ~w(steer sync async)}, effective_reason: {:enum, @listener_reasons}, version: :integer],
      reserved: true,
      owner: "orchestration"
    }
  ]

  # contracts/identity-and-capabilities.md §5 (MP-R1): clients re-read capabilities.
  @capabilities [
    %Entry{pattern: "system.capabilities.changed", class: :live, export?: true, attrs: [revision: :integer], owner: "identity"}
  ]

  # events-and-replay.md §9 (MP-E3): a namespace reservation, not a producer.
  @reserved [
    %Entry{pattern: "executor.conversation.#", class: :journaled, reserved: true, owner: "conversations"}
  ]

  @entries @decision ++ @queue_events ++ @queue ++ @listener ++ @capabilities ++ @reserved

  @spec entries() :: [Entry.t()]
  def entries, do: @entries
end
