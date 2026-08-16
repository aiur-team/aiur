# How a ticket flows

`issue → workspace → agent turn → draft PR → CI wait → review → merge`

| Step | State and operator meaning |
| --- | --- |
| Issue | `agent:todo` enters the dispatch queue after slot and blocker checks. |
| Workspace | Aiur provisions an isolated checkout with `logs/agent.md` and `logs/agent.ndjson`. |
| Agent turn | The agent works on its generated branch and keeps one `## Agent Workpad` current. |
| Draft PR | The agent opens a closing PR, runs the scoped local gate, and self-reviews. |
| CI wait | `agent:ci-wait` releases the turn while the central poller watches terminal checks. |
| Review | Passing work becomes `agent:human-review`; trusted feedback becomes `agent:rework`. |
| Merge | The agent never self-merges; a merged PR closes the issue and terminalizes `agent:done`. |

## Parking work

| State | Effect |
| --- | --- |
| No `agent:*` label | Invisible to dispatch until a human or authorized command assigns work. |
| `agent:parked` | Explicit hold; dispatch and comment-driven rework stay suppressed across state-label changes. |
| `agent:error` | Terminal execution failure needing operator handling. |
| `agent:cancelled` / `agent:canceled` | Terminal cancellation. |

Automatic CI and review transitions only apply to tickets already in the agent lifecycle; they never enroll an unlabelled issue.

## CI outcomes

| Result | Transition |
| --- | --- |
| Pass | Mark the PR ready and move to `agent:human-review`. |
| Failure | Return to `agent:rework` with failed-check context. |
| No terminal event | One bounded fallback re-wake performs a single recovery check. |

## Agent Workpad

| Property | Contract |
| --- | --- |
| Location | One pinned issue comment beginning `## Agent Workpad`. |
| Contents | Plan, validation, decisions, blockers, PR, and current handoff. |
| Updates | Edited in place across turns. |
| Event behavior | Filtered from comment polling so agent edits do not wake the ticket. |
