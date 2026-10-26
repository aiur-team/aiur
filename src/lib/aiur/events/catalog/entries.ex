defmodule Aiur.Events.Catalog.Entries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.{AttentionEntries, Entry, GithubSystemEntries, LegacyEntries, SystemEntries, TicketEntries}

  # aiur/decision_store/{requests,persistence,audit}.ex
  @decision_slugs ~w(requested answered pending-for-session session-started answer-comment-published expired mooted dismissed
    deferred executor-escalated authority-reclassified enriched revision-recorded queued dispatch-outcome-unknown revision-dispatched
    revision-no-longer-applicable revision-follow-up-required revision-follow-up-handled handed-off delivered restored consumed failed acknowledged resolved)
  # aiur/executor_wake_projection.ex
  @ci_conclusions ~w(success failure cancelled timed_out action_required neutral skipped stale)

  @spec entries() :: [Entry.t()]
  def entries do
    core() ++
      pull_requests() ++
      ci() ++
      comments() ++
      progress() ++
      SystemEntries.entries() ++ GithubSystemEntries.entries() ++ TicketEntries.entries() ++ AttentionEntries.entries() ++ LegacyEntries.entries()
  end

  defp core do
    [
      # aiur/agent_runner/tool_executor.ex; aiur/agent_tools/emit_event.ex
      %Entry{pattern: "ticket.*.agent.#", class: :logged, owner: "agent-runtime"},
      %Entry{pattern: "ticket.*.agent.custom.#", class: :logged, owner: "agent-runtime"},
      # aiur/decision_store/{audit,persistence}.ex
      %Entry{pattern: "ticket.*.agent.decision.#", class: :journaled, export?: true, refs: [:ticket, :decision_id, :decision_version], attrs: [slug: {:enum, @decision_slugs}], owner: "commands"},
      # aiur/executor_events.ex — private to the Executor principal.
      %Entry{pattern: "executor.#", class: :journaled, owner: "executor-attention"},
      # aiur/alerts.ex; aiur/agent_runner/tool_executor.ex
      Entry.alert("ticket.*.agent.attention.#", "agent-runtime"),
      Entry.alert("system.#", "signal")
    ]
  end

  # aiur/events/github_firehose/pull_request.ex; aiur/orchestrator/ready_for_review_transitions.ex
  defp pull_requests do
    for verb <- ~w(opened ready_for_review merged) do
      %Entry{pattern: "ticket.*.pr.#{verb}", class: :live, export?: true, refs: [:ticket, :pr_number, :head_sha], owner: "github-listeners"}
    end
  end

  # aiur/orchestrator/ci_lifecycle/terminal_event.ex
  defp ci do
    for outcome <- ~w(passed failed) do
      %Entry{pattern: "ticket.*.ci.#{outcome}", class: :live, export?: true, refs: [:ticket, :pr_number, :head_sha], attrs: [ci_conclusion: {:enum, @ci_conclusions}], owner: "orchestration"}
    end
  end

  # aiur/events/github_comments_poller/publish.ex; aiur/events/github_webhook/triples.ex
  defp comments do
    for suffix <- ~w(issue.commented pr.review_comment) do
      %Entry{pattern: "ticket.*.#{suffix}", class: :live, export?: true, refs: [:ticket, :pr_number], attrs: [author_trusted?: :boolean], owner: "github-listeners"}
    end
  end

  # aiur/agent_tools/emit_event.ex; aiur/agent_runner/tool_executor.ex
  defp progress do
    for suffix <- ~w(progress progress.checkin) do
      %Entry{pattern: "ticket.*.agent.#{suffix}", class: :logged, export?: true, attrs: [percent: :integer], owner: "agent-runtime"}
    end
  end
end
