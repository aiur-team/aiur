# Dashboard handoff

This is the durable orientation for maintaining the shipped Dashboard. The directory name and `OCC-*` ticket identifiers are historical implementation references; **Dashboard** is the user-facing product name.

## Shipped state

The backend, LiveView UI, and integration capstone are on `main`:

- OCC-1 records the canonical Decision and append-only audit.
- OCC-2 projects coordination attentions into decisions.
- OCC-3 persists answers before dispatch and correlates delivery.
- OCC-5 expands fleet and waiting-state projection.
- OCC-6 projects decision history and recent repository outcomes.
- OCC-7 exposes the separately authenticated supervising-Executor API.
- OCC-8 records append-only revisions and follow-up outcomes.
- OCC-9 retains decision lifecycle latency metrics.
- OCC-4 provides the responsive LiveView surface.
- OCC-10 proves the integrated answer, delivery, revision, acknowledgement, resolution, fleet, history, outcome, and latency paths.

The numbered contract documents in this directory remain the implementation sources of truth. Do not replace them with this summary.

## Ownership boundaries

| Capability | Canonical owner | Control Center responsibility |
| --- | --- | --- |
| Human answer and retry | `Aiur.DecisionStore` and `Aiur.DecisionDispatch` | Submit a human-attributed command and reload canonical state. |
| Supervising-Executor decision | `Aiur.DecisionApi` behind bearer authentication and policy | Render the same Decision projection without borrowing machine authority for human actions. |
| Revision and follow-up | OCC-8 revision APIs | Append a correction and preserve every prior action. |
| Acknowledgement and resolution | Correlated target-agent events | Render the recorded lifecycle; never advance it in the browser. |
| History | `Aiur.DecisionHistory` | Render provider rows without rebuilding audit events. |
| Recent outcomes | `Aiur.RecentMergeStore` | Render durable provider rows without polling GitHub per request. |
| Decision latency | `Aiur.DecisionMetrics` | Bulk-read retained snapshots and preserve missing/unavailable states. |
| Fleet state | `Aiur.Orchestrator` snapshot | Render the live projection and explicit waiting reasons. |

`Aiur.DecisionStore` remains the sole Decision writer. The LiveView is a command surface and projection consumer, not a parallel workflow engine.

## Security posture

- Read-only loopback is the default browser posture.
- `observability.dashboard_writable: true` explicitly enables human mutation controls.
- Writable or non-loopback dashboard startup requires `AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD`.
- Writable requests additionally require same-origin evidence and `X-Aiur-Request: 1`.
- The supervisor API uses the separate `AIUR_SUPERVISOR_TOKEN` bearer credential and the same writable/origin mutation gates.

Never put real credentials, customer data, repository history, or agent transcripts in documentation fixtures or screenshots.

## Documentation and visual regression

The public guide is `website/docs-app/guide/gui.md`. Its screenshots are produced by:

```bash
cd website
npm ci
npm run shot:dashboard
```

The command starts the shipped Phoenix endpoint with the isolated fixture at `src/test/manual/executor_control_center_docs_fixture.exs`. All visible values use synthetic `EX-*` tickets and `example.test` URLs. Keep the capture script and guide aligned with component and terminology changes.

## Executor-root acceptance drive

The deterministic fixture validates rendering and documentation privacy. Final interactive acceptance still belongs in the Executor repository root because generated issue workspaces are forbidden from running `scripts/aiurdev --test`.

Use the wrapper/inner-tmux procedure in the repository `AGENTS.md`, then exercise the real run:

1. Record a reversible, human-required decision from a running synthetic ticket.
2. Open its stable `/commands/:decision_id` deep link and verify Recorded state and latency.
3. Answer in the writable dashboard and observe correlated delivery in the target chat.
4. Revise the answer and confirm the original and correction remain in History.
5. Have the target emit the exact correlated acknowledgement and resolution events.
6. Confirm Delivered → Acknowledged → Resolved, then verify Fleet, outcomes, and latency.
7. Return to read-only mode and confirm mutations disappear while projections remain.

Stop the run with `scripts/aiurdev stop`. Do not substitute direct HTTP mutation calls or log-only evidence for this interactive acceptance drive.
