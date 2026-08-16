# Dashboard

This is the planning and implementation-contract home for the **Dashboard
(OCC)** — extending Aiur's existing LiveView dashboard into a
decision inbox, fleet-state view, and history control surface for a human
Executor overseeing the fleet.

The directory and `OCC-*` ticket identifiers preserve the historical Operator
Control Center wave name; shipped UI and current prose use Executor
terminology.

## Layout

| File | What it is | Owner |
|---|---|---|
| `00-prd.md` | The feature scope / PRD (the source of truth for what OCC is) | Executor's doc |
| `01-brainstorm-and-decomposition.md` | CE-brainstorm grounding, the scoping decisions, and the ticket breakdown | this session |
| `02-occ-0-audit-and-design-decisions.md` | Accepted architecture audit and cross-ticket design decisions | OCC-0 |
| `03-occ-1-decision-contract.md` | Durable request schema/store handoff | OCC-1 |
| `04-occ-2-attention-adapter.md` | Legacy attention-to-Decision compatibility boundary | OCC-2 |
| `04-occ-3-answer-delivery-contract.md` | Answer, dispatch, transport, and agent acknowledgement handoff | OCC-3 |
| `05-occ-8-decision-revision-contract.md` | Append-only revision, corrective dispatch, and blocking follow-up handoff | OCC-8 |
| `06-occ-7-supervisor-decision-api-contract.md` | Supervisor auth, policy, machine routes, and sibling delegation handoff | OCC-7 |
| `EXECUTOR-HANDOFF.md` | Shipped ownership, security, documentation, and acceptance handoff | docs closeout |
| `claude-design-prompt.md` | Ready-to-send prompt → Claude builds a self-contained HTML mock with example data | design handoff |

## Decisions locked (from the brainstorm)

1. **Full scope is v1**, decomposed into **many parallelizable tickets** (not a single mega-PR).
2. **Claude designs a mock** (HTML artifact). The **UI ticket is blocked** on the Executor sending that mock's URL; the agent then productionizes it into LiveView.
3. **Link, don't merge**, with #930's offline telemetry/analytics dashboard — two separate surfaces.
4. Tickets route to **codex 5.6 sol / max** (heavy model).

## Implementation status

OCC-0 established the architecture decisions, OCC-1 delivered the durable
Decision request store, OCC-3 added persist-before-dispatch answer delivery,
and OCC-8 extended that same audit/outbox with ordered revisions. OCC-7 exposes
those contracts through a separately authenticated, fail-closed supervising-Executor API.
The LiveView now drives the human answer and revision boundaries directly and
renders OCC-6 history/outcomes and OCC-9 latency from their canonical providers.
Follow the numbered contract docs rather than reconstructing behavior from
individual implementation tickets.

## Integrated ownership

| Capability | Canonical owner | Dashboard responsibility |
|---|---|---|
| Human answer and retry | `Aiur.DecisionStore` + `Aiur.DecisionDispatch` | Submit an Executor-attributed command and reload canonical state |
| Supervisor enrich/decide/revise | `Aiur.DecisionApi` behind supervisor authentication and policy | Render the shared Decision projection; never borrow supervisor authority for human actions |
| Human revision and follow-up | `Aiur.DecisionStore` OCC-8 revision APIs | Submit an append-only correction and render original/revised actions |
| History | `Aiur.DecisionHistory` over the Decision audit store | Render provider rows without rebuilding lifecycle events |
| Recent outcomes | `Aiur.RecentMergeStore` | Render provider rows without polling GitHub |
| Decision latency | `Aiur.DecisionMetrics` | Bulk-read retained snapshots and render missing/unavailable states explicitly |
| Fleet state | `Aiur.Orchestrator` snapshot | Render the live provider projection |

`Aiur.DecisionStore` remains the sole Decision writer. Delivery,
acknowledgement, resolution, history, and latency are consequences of its real
append-only lifecycle; the LiveView does not synthesize transitions.

## Executor-root acceptance drive

This is the required running-daemon check for the integrated control center.
Run it from the Executor repository root. `--test` is deliberately blocked in
generated agent issue workspaces because it resets pinned sandbox tickets; do
not copy the checkout or substitute HTTP calls or log inspection for this
drive-through.

1. Enable a private writable dashboard in the test configuration:

   ```yaml
   observability:
     dashboard_writable: true
   server:
     host: 127.0.0.1
     port: 4000
   ```

2. Launch the real foreground CLI from the Executor checkout:

   ```bash
   scripts/aiurdev --test --force --allow-remote
   ```

   A non-TTY driver must use the wrapper/inner-tmux recipe in the repository
   `AGENTS.md`, then interact with the inner AgentList and chat pane using
   `tmux send-keys` and `tmux capture-pane`.

3. Open a running agent's chat pane and send an Executor message asking it to
   emit a real `decision.requested` event for its own ticket. Use a reversible
   `human_required` architecture decision with at least two options so both the
   authority badge and choice controls are visible. Confirm the chat renders
   the outgoing tool call rather than merely describing it.

4. Open `http://127.0.0.1:4000/decisions`, select the new inbox row, and copy
   its `/decisions/<decision-id>` URL. Reload that URL directly to prove the
   stable deep link resolves. Confirm the detail initially shows the request,
   open lifecycle, and a real latency state (`Pending` is valid before the
   corresponding lifecycle edge exists).

5. Answer from the dashboard. Confirm the UI first reports the durable answer
   as recorded/dispatch-pending, then shows the correlated queue delivery. In
   the agent chat, observe the actual durable Executor-answer message with the
   same Decision ID, action ID, and request version.

6. Before resolving, use **Revise decision** to record a different answer and
   reason. Confirm the detail and History preserve the original action and show
   `Revision 1`; then observe the corrective correlated message in the agent
   chat. If the target is no longer active, verify the real follow-up-required
   state instead of expecting a fabricated delivery.

7. Let the target agent emit the exact `decision.acknowledged` and
   `decision.resolved` events using the correlation fields from the active
   answer message. Confirm the browser advances through Delivered →
   Acknowledged → Resolved and that History records the Executor, target-agent,
   dispatch, revision, acknowledgement, and resolution facts.

8. Return to `/` and verify Fleet, Recent outcomes, and Decision history are
   populated from the running daemon. Reopen the decision and verify Decision
   latency shows the available request/decision/dispatch/delivery/ack timings,
   blocked time, actor, and revised marker. Finally switch the configuration
   back to read-only and confirm all mutation forms disappear while every read
   panel and deep link remains available.

Stop the run with `scripts/aiurdev stop` and clean up the wrapper tmux server if
one was used.
