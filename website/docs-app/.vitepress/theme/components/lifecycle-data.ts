export type LifecycleKind = 'command' | 'emit' | 'consume' | 'note'
export type LifecycleActor = 'Executor' | 'CI' | 'Aiur agent' | 'Aiur daemon'

export interface LifecycleItem {
  at: number
  actor: LifecycleActor
  kind: LifecycleKind
  label: string
  topic?: string
  source?: string
}

export const phases = [
  ['Queued', 0, 0.08], ['Dispatch', 0.08, 0.115], ['Plan', 0.115, 0.165],
  ['Implement', 0.165, 0.355], ['Test', 0.355, 0.44], ['PR', 0.44, 0.5],
  ['Review', 0.5, 0.68], ['CI', 0.68, 0.74], ['Merge queue', 0.74, 0.855],
  ['Land', 0.855, 0.9], ['Deploy', 0.9, 1]
] as const

// Reported progress estimates are illustrative positions, not durations or guarantees.
export const progress = [
  { percent: 0, at: 0 }, { percent: 5, at: 0.1 }, { percent: 10, at: 0.125 },
  { percent: 25, at: 0.21 }, { percent: 40, at: 0.3 }, { percent: 60, at: 0.4 },
  { percent: 75, at: 0.49 }, { percent: 85, at: 0.67 }, { percent: 90, at: 0.73 },
  { percent: 95, at: 0.86 }, { percent: 100, at: 0.985 }
]

// Event sources are code locations and are not rendered. Equal `at` values keep each emit and consumer together.
export const items: LifecycleItem[] = [
  { at: 0.005, actor: 'Executor', kind: 'command', label: 'gh issue create --label agent:todo' },
  { at: 0.025, actor: 'Executor', kind: 'command', label: 'aiur queue add 142 143 --queue paseo' },
  { at: 0.045, actor: 'Executor', kind: 'note', label: 'Ticket waits for dispatch authorization and capacity.' },
  { at: 0.03, actor: 'Aiur daemon', kind: 'note', label: 'Build Queue promotes an eligible member.' },
  { at: 0.08, actor: 'Aiur daemon', kind: 'note', label: 'Dispatch authorization poll begins.' },
  { at: 0.088, actor: 'Aiur daemon', kind: 'note', label: 'Capacity gates pass.' },
  { at: 0.096, actor: 'Aiur daemon', kind: 'note', label: 'Ticket is claimed as in progress.' },
  { at: 0.103, actor: 'Aiur daemon', kind: 'note', label: 'Workspace setup runs before the agent.' },
  { at: 0.11, actor: 'Aiur daemon', kind: 'note', label: 'Aiur selects an account and starts the agent.' },
  { at: 0.115, actor: 'Aiur agent', kind: 'note', label: 'Read the ticket, plan, and update the workpad.' },
  { at: 0.125, actor: 'Aiur agent', kind: 'emit', label: 'phase.work.start', topic: 'ticket.N.agent.phase.work.start', source: 'src/lib/aiur/agent_runner/tool_executor.ex:119-129; src/lib/aiur/agent_runner/tool_events.ex:13-25; src/lib/aiur/agent_list/renderer/event_phrases.ex:5' },
  { at: 0.125, actor: 'Aiur daemon', kind: 'consume', label: 'Displays the phase in the agent list', topic: 'ticket.N.agent.phase.work.start', source: 'src/lib/aiur/agent_list/renderer/event_phrases.ex:5' },
  { at: 0.14, actor: 'Aiur agent', kind: 'note', label: 'Post the workpad comment on the issue.' },
  { at: 0.21, actor: 'Aiur agent', kind: 'emit', label: 'Progress · 25%', topic: 'ticket.N.agent.progress', source: 'src/lib/aiur/agent_runner/tool_events.ex:85-99; src/lib/aiur/agent_tools/emit_event.ex:145-147; src/lib/aiur/agent_list/renderer/event_phrases.ex:13,71' },
  { at: 0.21, actor: 'Aiur daemon', kind: 'consume', label: 'Updates the agent-list progress bar', topic: 'ticket.N.agent.progress', source: 'src/lib/aiur/agent_list/activity_intake.ex:101-108; src/lib/aiur/agent_list/renderer/cells.ex:80' },
  { at: 0.29, actor: 'Aiur daemon', kind: 'emit', label: 'operator.progress_request', topic: 'ticket.N.operator.progress_request', source: 'src/lib/aiur/progress_checkin/worker.ex:90' },
  { at: 0.29, actor: 'Aiur agent', kind: 'consume', label: 'Receives the periodic check-in at a turn boundary', topic: 'ticket.N.operator.progress_request', source: 'src/lib/aiur/events/universal_subscriptions.ex:37' },
  { at: 0.3, actor: 'Aiur agent', kind: 'emit', label: 'progress.checkin', topic: 'ticket.N.agent.progress.checkin', source: 'src/lib/aiur/agent_runner/tool_events.ex:85-99; src/lib/aiur/agent_tools/emit_event.ex:145-147; src/lib/aiur/agent_list/renderer/event_phrases.ex:8' },
  { at: 0.3, actor: 'Aiur daemon', kind: 'consume', label: 'Records the check-in in ticket activity', topic: 'ticket.N.agent.progress.checkin', source: 'src/lib/aiur/ticket_activity/projection.ex:393' },
  { at: 0.37, actor: 'Aiur agent', kind: 'command', label: 'mise exec -- mix test --max-cases 4 <affected tests>' },
  { at: 0.4, actor: 'Aiur agent', kind: 'emit', label: 'Progress · 60%', topic: 'ticket.N.agent.progress', source: 'src/lib/aiur/agent_runner/tool_events.ex:85-99; src/lib/aiur/agent_tools/emit_event.ex:145-147; src/lib/aiur/agent_list/renderer/event_phrases.ex:13,71' },
  { at: 0.415, actor: 'Aiur agent', kind: 'command', label: 'aiur pre-pr' },
  { at: 0.445, actor: 'Aiur agent', kind: 'command', label: 'git commit -F <msg> && git push' },
  { at: 0.455, actor: 'Aiur daemon', kind: 'emit', label: 'branch.push · git ls-remote poll', topic: 'ticket.N.branch.push', source: 'src/lib/aiur/events/ls_remote_ticker.ex:139-187' },
  { at: 0.455, actor: 'Executor', kind: 'consume', label: 'Durable Executor wake', topic: 'ticket.N.branch.push', source: 'src/lib/aiur/executor_bindings.ex:32' },
  { at: 0.455, actor: 'Aiur daemon', kind: 'consume', label: 'Routes a blocker push to dependent tickets', topic: 'ticket.N.branch.push', source: 'src/lib/aiur/orchestrator/event_topics.ex:99-110' },
  { at: 0.47, actor: 'CI', kind: 'note', label: 'PR opens on GitHub; checks start for the pushed head.' },
  { at: 0.475, actor: 'Aiur agent', kind: 'command', label: 'gh pr create --draft --head <branch> --base main --body-file <template>' },
  { at: 0.485, actor: 'Aiur daemon', kind: 'emit', label: 'pr.opened · GitHub event', topic: 'ticket.N.pr.opened', source: 'src/lib/aiur/events/github_firehose.ex:454-455; src/lib/aiur/events/github_webhook/triples.ex:345' },
  { at: 0.485, actor: 'Executor', kind: 'consume', label: 'Durable Executor wake', topic: 'ticket.N.pr.opened', source: 'src/lib/aiur/executor_bindings.ex:31' },
  { at: 0.485, actor: 'Aiur daemon', kind: 'consume', label: 'Reconciles optimistic blocker state', topic: 'ticket.N.pr.opened', source: 'src/lib/aiur/orchestrator/event_topics.ex:51-52,237-238,308-312' },
  { at: 0.49, actor: 'Aiur agent', kind: 'emit', label: 'Progress · 75%', topic: 'ticket.N.agent.progress', source: 'src/lib/aiur/agent_runner/tool_events.ex:85-99; src/lib/aiur/agent_tools/emit_event.ex:145-147; src/lib/aiur/agent_list/renderer/event_phrases.ex:13,71' },
  { at: 0.545, actor: 'Aiur agent', kind: 'emit', label: 'phase.review.end', topic: 'ticket.N.agent.phase.review.end', source: 'src/lib/aiur/agent_runner/tool_executor.ex:119-129; src/lib/aiur/agent_runner/tool_events.ex:13-25; src/lib/aiur/agent_list/renderer/event_phrases.ex:5' },
  { at: 0.545, actor: 'Aiur daemon', kind: 'consume', label: 'Displays the review phase in the agent list', topic: 'ticket.N.agent.phase.review.end', source: 'src/lib/aiur/agent_list/renderer/event_phrases.ex:5' },
  { at: 0.56, actor: 'Aiur agent', kind: 'note', label: 'Hands the ticket to human review.' },
  { at: 0.57, actor: 'Aiur daemon', kind: 'emit', label: 'handoff.human_review · label transition', topic: 'ticket.N.agent.handoff.human_review', source: 'src/lib/aiur/orchestrator/issue_sync/transition_alerts.ex:124-129' },
  { at: 0.57, actor: 'Executor', kind: 'consume', label: 'Durable handoff wake', topic: 'ticket.N.agent.handoff.human_review', source: 'src/lib/aiur/executor_bindings.ex:40' },
  { at: 0.585, actor: 'Aiur daemon', kind: 'emit', label: 'pr.ready_for_review · GitHub state poll', topic: 'ticket.N.pr.ready_for_review', source: 'src/lib/aiur/orchestrator/ready_for_review_transitions.ex:171-176; src/lib/aiur/events/github_webhook/triples.ex:346' },
  { at: 0.585, actor: 'Executor', kind: 'consume', label: 'Wake unless head matches the last-reviewed SHA', topic: 'ticket.N.pr.ready_for_review', source: 'src/lib/aiur/executor_bindings.ex:52; src/lib/aiur/executor_wake_projection.ex:16-20' },
  { at: 0.6, actor: 'Executor', kind: 'command', label: 'aiur executor-wait --timeout 60 --json' },
  { at: 0.62, actor: 'Executor', kind: 'note', label: 'Reviewer checks the diff and required checks.' },
  { at: 0.645, actor: 'Executor', kind: 'command', label: 'gh pr review --approve' },
  { at: 0.655, actor: 'Executor', kind: 'command', label: 'aiur pr merge <N> --reviewed-sha <sha>' },
  { at: 0.665, actor: 'Aiur daemon', kind: 'emit', label: 'pr.review_comment · GitHub poll or webhook', topic: 'ticket.N.pr.review_comment', source: 'src/lib/aiur/events/github_comments_poller/publish.ex:48-60; src/lib/aiur/events/github_webhook/triples.ex:92-100' },
  { at: 0.665, actor: 'Aiur agent', kind: 'consume', label: 'Review comment wakes the agent', topic: 'ticket.N.pr.review_comment', source: 'src/lib/aiur/events/universal_subscriptions.ex:34; src/lib/aiur/orchestrator/lifecycle.ex:37' },
  { at: 0.665, actor: 'Aiur daemon', kind: 'consume', label: 'Routes review feedback to CommentWake', topic: 'ticket.N.pr.review_comment', source: 'src/lib/aiur/orchestrator/event_topics.ex:34-38' },
  { at: 0.68, actor: 'Aiur daemon', kind: 'note', label: 'Approval and PR state move the ticket to CI wait.' },
  { at: 0.725, actor: 'CI', kind: 'note', label: 'Required checks pass on the current head.' },
  { at: 0.73, actor: 'Aiur daemon', kind: 'emit', label: 'ci.passed · CI lifecycle poll', topic: 'ticket.N.ci.passed', source: 'src/lib/aiur/orchestrator/ci_lifecycle/terminal_event.ex:19-20' },
  { at: 0.73, actor: 'Executor', kind: 'consume', label: 'Durable CI wake', topic: 'ticket.N.ci.passed', source: 'src/lib/aiur/executor_bindings.ex:50' },
  { at: 0.73, actor: 'Aiur agent', kind: 'consume', label: 'CI result delivered to the active agent', topic: 'ticket.N.ci.passed', source: 'src/lib/aiur/events/universal_subscriptions.ex:35' },
  { at: 0.73, actor: 'Aiur daemon', kind: 'consume', label: 'Advances the CI lifecycle', topic: 'ticket.N.ci.passed', source: 'src/lib/aiur/orchestrator/event_topics.ex:57-58' },
  { at: 0.74, actor: 'CI', kind: 'note', label: 'Auto-merge queues the PR after required checks.' },
  { at: 0.78, actor: 'CI', kind: 'note', label: 'Merge-group checks run on the queue branch.' },
  { at: 0.858, actor: 'CI', kind: 'note', label: 'Squash merge lands; a closing PR body closes the issue.' },
  { at: 0.862, actor: 'Aiur daemon', kind: 'emit', label: 'pr.merged · GitHub event', topic: 'ticket.N.pr.merged', source: 'src/lib/aiur/events/github_firehose.ex:454-455; src/lib/aiur/events/github_webhook/triples.ex:347' },
  { at: 0.862, actor: 'Executor', kind: 'consume', label: 'Durable merge wake', topic: 'ticket.N.pr.merged', source: 'src/lib/aiur/executor_bindings.ex:33' },
  { at: 0.862, actor: 'Aiur daemon', kind: 'consume', label: 'Merge lifecycle and queue routing', topic: 'ticket.N.pr.merged', source: 'src/lib/aiur/orchestrator/event_topics.ex:43-49' },
  { at: 0.87, actor: 'Executor', kind: 'emit', label: 'system.pr.merged · verified merge observation', topic: 'system.pr.merged', source: 'src/lib/aiur/pr_merge/record.ex:64-85' },
  { at: 0.87, actor: 'Executor', kind: 'consume', label: 'Durable system merge wake', topic: 'system.pr.merged', source: 'src/lib/aiur/executor_bindings.ex:27' },
  { at: 0.88, actor: 'Aiur agent', kind: 'note', label: 'Worker exits; lifecycle cleanup handles its workspace.' },
  { at: 0.915, actor: 'Executor', kind: 'note', label: 'Deployment follows the operator’s release process.' },
  { at: 0.945, actor: 'Executor', kind: 'command', label: 'aiurdev status' },
  { at: 0.975, actor: 'Executor', kind: 'note', label: 'Confirm the deployment and application health.' }
]
