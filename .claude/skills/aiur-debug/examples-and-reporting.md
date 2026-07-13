# Worked examples and reporting

These examples show how `/aiur-debug` contributes Aiur context while a general
debugging companion owns hypotheses, causal analysis, and validation.

## Worked example: duplicated test command

**Symptom:** two identical `mix test` processes appeared for one ticket.

**Overlay evidence:** join the workspace NDJSON with the process tree:

```text
ticket=<ticket> thread=th-7 turn=turn-3 item=call-21 command="mix test ..."
ticket=<ticket> thread=th-7 turn=turn-3 item=call-22 command="mix test ..."
generation=1 item=call-21 process_group=pg-4 children=[shell,mix,beam]
generation=1 item=call-22 process_group=pg-5 children=[shell,mix,beam]
```

The distinct `call-21` and `call-22` IDs within one thread/turn prove the agent
invoked the command twice. The two correlated process groups show the two calls
executed, while one worker generation is counter-evidence to duplicate agent
dispatch; multiple Mix/BEAM children inside either group are normal command
fan-out. Record whether the process census came from the issue sandbox or the
host/operator context, because the sandbox can hide sibling host groups.

**Composition:** hand this classification to native `/debug` or installed
`/ce-debug` to determine why the agent workflow selected two calls and how to
validate a correction. Do not file an Aiur replay bug from process count alone.

If both records instead carried the identical item `call-21`, the next question
would be delivery/replay state. An identical item replay with two accepted side
effects points to transport/deduplication; overlapping worker generations point
to dispatch. Those are separate hypotheses owned by the companion skill.

## Worked example: tracker-paused ticket

**Symptom:** an eligible ticket is visible in GitHub but never starts.

**Overlay evidence:** active config contains the `todo` slug; GitHub returns
both `agent:todo` and `agent:paused`; `watch --full` has no dispatch record; the
native blocker graph is empty; capacity and tracker polls are healthy.

**Classification:** expected suppressing override. `agent:paused` is not an
active state and deliberately preserves the underlying state label. Absence of
a dispatch is not an orchestrator defect.

**Composition:** no generic root-cause workflow is needed unless the pause was
unexpected. If it was, use `/debug` or `/ce-debug` to trace who/what applied the
label. With operator intent and preserved before-state, remove only
`agent:paused`; removing `agent:todo` would destroy the preserved workflow
state.

## Worked example: no dashboard listener on a non-loopback bind

**Symptom:** the dashboard port has no listener, but agents are running.

**Overlay evidence:** `scripts/aiurdev status` answers at the matching instance;
config requests a non-loopback host; neither dashboard auth variable is
present; `aiur.log` records that the dashboard refused to bind without basic
auth; no listener owns the configured port.

**Classification:** expected security gate in `Aiur.HttpServer`, not daemon
failure. A read-only non-loopback dashboard and every writable dashboard
require both credentials. Loopback read-only is the unauthenticated exception.

**Composition:** if credentials are present but the listener still does not
start, hand the bind/log evidence to `/debug` or `/ce-debug` and add Phoenix or
host-network diagnostics when available. Recovery is to bind read-only on
`127.0.0.1` or configure both credentials without printing them. Widening bind
exposure or dashboard writability requires explicit operator intent.

## Worked example: genuine orchestrator retry/replay defect

**Symptom:** one completed agent turn caused the same external action twice.

**Overlay evidence:**

```text
ticket=204 generation=8 thread=th-9 turn=turn-5 item=call-31 event=evt-88
provider terminal=completed
queue item=q-12 dedupe_key=evt-88 delivery_attempt=1 accepted=true
retry generation=9 reason=turn_completed
thread=th-9 turn=turn-5 item=call-31 event=evt-88
queue item=q-19 dedupe_key=evt-88 delivery_attempt=1 accepted=true
```

The provider completed successfully. Aiur then created a new generation with a
completion reason, replayed the **same** thread/turn/item/event identity, and
accepted a second queue item instead of returning duplicate. Separate durable
side effects confirm impact. This is not two agent choices (the item ID is
identical), provider retry (provider was terminal), or process fan-out.

**Classification:** high-confidence Aiur retry/deduplication defect at the
orchestrator/queue boundary.

**Composition:** give the normalized timeline and correlation set to `/debug`
or `/ce-debug` for causal-chain investigation, a minimal replay test, and fix
validation. Add provider-native diagnostics only if the provider terminal
record is disputed. Contain by pausing the one ticket/consumer after preserving
audit state; do not delete the queue or replay store.

## Concise diagnostic report

```markdown
## Diagnostic report

**Symptom / impact:** <observable behavior and affected scope>
**Investigation window (UTC):** <start> to <end>

### Correlation
- Repository + ticket: <project>, <canonical issue ID>
- Run + instance: <log/session root>, <instance key>, <node>, <tmux socket/session>
- Agent/provider: <generation>, <backend/model>, <thread>, <turn>, <item/tool-call>, <PID/PGID>
- Workspace/Git/PR: <repo-relative workspace descriptor>, <branch>, <HEAD>, <PR>, <head/base SHA>
- Event/delivery: <event ID>, <source ticket/topic>, <causation/correlation>, <queue/delivery/ack state>

### Normalized timeline
| UTC | Source | Correlation | Observation | Authority/caveat |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

### Evidence
- <authoritative observation>

### Counter-evidence
- <plausible class ruled out and why>

**Classified layer/root cause:** <Aiur orchestration | agent/model | transport | tracker | repository | resource/build | expected state>
**Confidence:** <high | medium | low> — <why>
**Containment/recovery performed:** <action or none; blast radius and post-check>
**Remaining uncertainty:** <specific missing boundary>
**Disposition:** <fix in owning ticket | defer P2/P3 | independent reproducible P0/P1 issue>
```

### Disposition rule

- Fix in the owning ticket when the cause and correction are required for that
  ticket's acceptance and do not materially expand scope.
- Record/defer as P2/P3 when impact is bounded, a safe workaround exists, and
  the finding is not required to ship the owning ticket.
- File an independent P0/P1 only for urgent, reproducible cross-ticket/systemic
  impact with joined IDs, minimal evidence, and a clear owning layer. Severity
  is impact/urgency, not investigator frustration.

## Sanitized bug-report checklist

- [ ] Minimal reproducible symptom, expected behavior, impact, and UTC window.
- [ ] Repository-relative paths and sanitized placeholders; no machine-specific
      checkout, logs-root, workspace-root, or state-directory path.
- [ ] Exact non-sensitive ticket/run/session/turn/item/event IDs and relevant
      Git/PR SHAs needed to distinguish replay from a fresh action.
- [ ] Small log excerpts with unrelated payload/source removed.
- [ ] Evidence and counter-evidence for the classified layer.
- [ ] Reproduction preconditions and whether real TUI/browser evidence was
      required and captured.
- [ ] Containment/recovery, blast radius, and whether evidence was preserved
      before mutation.
- [ ] Companion workflow used (`/debug`, `/ce-debug` when available, and any
      provider-native diagnostic capability).
- [ ] No secrets, credentials, tokens, cookies, authorization headers, private
      prompts/content, account identifiers, email addresses, personal
      hostnames/IPs, or irrelevant source/configuration.
- [ ] No full agent transcript when a few redacted records and stable
      repository-relative paths reproduce the issue.
- [ ] Verify redaction did not destroy the join keys needed to reproduce.

Prefer placeholders such as `<logs-root>`, `<workspace>`, `<ticket>`,
`<thread>`, and `<event-id>`. Never paste `.env`, auth configuration values,
provider account details, or private issue/agent content into a public issue.
