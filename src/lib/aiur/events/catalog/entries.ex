defmodule Aiur.Events.Catalog.Entries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.{AttentionEntries, Entry, GithubSystemEntries, LegacyEntries, PlannedEntries, SystemEntries, TicketEntries}

  # aiur/decision_store/{requests,persistence,audit}.ex
  @decision_slugs ~w(requested answered pending-for-session session-started answer-comment-published expired mooted dismissed
    deferred executor-escalated authority-reclassified enriched revision-recorded queued dispatch-outcome-unknown revision-dispatched
    revision-no-longer-applicable revision-follow-up-required revision-follow-up-handled handed-off delivered restored consumed failed acknowledged resolved)
  # aiur/executor_wake_projection.ex
  @ci_conclusions ~w(success failure cancelled timed_out action_required neutral skipped stale)

  @core [
    # aiur/agent_runner/tool_executor.ex; aiur/agent_tools/emit_event.ex
    %Entry{pattern: "ticket.*.agent.#", class: :logged, owner: "harness-adapters"},
    %Entry{pattern: "ticket.*.agent.custom.#", class: :logged, owner: "harness-adapters"},
    # aiur/decision_store/{audit,persistence}.ex
    %Entry{pattern: "ticket.*.agent.decision.#", class: :journaled, export?: true, refs: [:ticket, :decision_id, :decision_version], attrs: [slug: {:enum, @decision_slugs}], owner: "commands"},
    # aiur/executor_events.ex — private to the Executor principal.
    %Entry{pattern: "executor.#", class: :journaled, owner: "executor-attention"},
    # aiur/alerts.ex; aiur/agent_runner/tool_executor.ex
    Entry.alert("ticket.*.agent.attention.#", "harness-adapters", export?: true),
    Entry.alert("system.#", "signal", export?: true)
  ]

  # aiur/events/github_firehose/pull_request.ex; aiur/orchestrator/ready_for_review_transitions.ex
  @pull_requests (for verb <- ~w(opened ready_for_review merged) do
                    %Entry{pattern: "ticket.*.pr.#{verb}", class: :live, export?: true, refs: [:ticket, :pr_number, :head_sha], owner: "github-listeners"}
                  end)

  # aiur/orchestrator/ci_lifecycle/terminal_event.ex
  @ci (for outcome <- ~w(passed failed) do
         %Entry{pattern: "ticket.*.ci.#{outcome}", class: :live, export?: true, refs: [:ticket, :pr_number, :head_sha], attrs: [ci_conclusion: {:enum, @ci_conclusions}], owner: "orchestration"}
       end)

  # aiur/events/github_comments_poller/publish.ex; aiur/events/github_webhook/triples.ex
  @comments (for suffix <- ~w(issue.commented pr.review_comment) do
               %Entry{pattern: "ticket.*.#{suffix}", class: :live, export?: true, refs: [:ticket, :pr_number], attrs: [author_trusted?: :boolean], owner: "github-listeners"}
             end)

  # aiur/agent_tools/emit_event.ex; aiur/agent_runner/tool_executor.ex
  @progress (for suffix <- ~w(progress progress.checkin) do
               %Entry{pattern: "ticket.*.agent.#{suffix}", class: :logged, export?: true, attrs: [percent: :integer], owner: "harness-adapters"}
             end)

  @entries @core ++
             @pull_requests ++
             @ci ++
             @comments ++
             @progress ++
             PlannedEntries.entries() ++ SystemEntries.entries() ++ GithubSystemEntries.entries() ++ TicketEntries.entries() ++ AttentionEntries.entries() ++ LegacyEntries.entries()

  @spec entries() :: [Entry.t()]
  def entries, do: @entries
end
