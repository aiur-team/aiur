# Aiur / IR Optimization Pillars v2 — Dashboard Analytics + Cloud Execution Spike

_Date: 2026-07-08_

_Status: implementation-planning brief for an Aiur/IR implementing agent after the current refactor._

## 0. Purpose

This document updates the previous Aiur / IR optimization-pillar brief with two additional categories of work:

1. **Visualization, analytics, and dashboard control** — make Aiur’s dashboard useful for understanding cost, token usage, run health, agent conversations, routing decisions, labels, rate limits, and per-ticket outcomes.
2. **Cloud / containerized execution** — move from one local Aiur process running agents on a NUC/MacBook to a controller/worker architecture where each agent run can execute in an isolated cloud container while preserving communication, observability, and cost attribution.

The goal is not to implement every pillar at once. The goal is to give an implementing agent a grounded map of the work, the existing Aiur surfaces, recommended architecture, risks, and a realistic v1 cutline.

## 1. Executive Summary

Aiur already owns the orchestration loop: it polls tracker items, creates isolated workspaces, launches Codex or Claude, drives repeated turns, exposes CLI and LiveView observability, and has event-based coordination. The new dashboard/cloud ideas should extend that architecture rather than replace it.

The updated optimization pillars are:

1. **Measurement / run ledger substrate**
   - Add durable, queryable metrics first. Every other optimization needs stable run IDs, issue IDs, token counts, cost estimates, model/backend metadata, timestamps, outcomes, and routing decisions.

2. **Context / token optimization**
   - Reduce prompt and tool-output token usage through role-specific skills, command-output minification, prompt-section budgets, and wrapper summaries.

3. **Role / phase-based workflows**
   - Stop giving every agent the same all-purpose skill bundle. Add roles such as architect, engineer, reviewer, tester, investigator, coordinator, and maintainer.

4. **Agent-to-agent messaging and viewability**
   - Evolve Aiur’s existing event bus into typed direct messages, inboxes, conversation threads, and dashboard/CLI views.

5. **Durable memory with Omnigraph**
   - Reduce repeated churn by storing durable knowledge about recurring failures, fixes, tests, files, decisions, and refactor signals.

6. **Visualization, analytics, and dashboard control**
   - Upgrade the current dashboard from “live observability plus limited gated write controls” into a control plane for conversations, labels, routing, cost, token usage, rate-limit state, cloud workers, and run outcomes.

7. **Cloud / containerized execution**
   - Add a controller/worker execution model so one Aiur controller can dispatch many isolated agent runs to cloud containers and still collect logs, messages, metrics, costs, and final PR outcomes.

## 2. Main Recommendation

Do **not** bolt all pillars on at once.

The best sequence is:

1. **Run ledger / metrics substrate**
   - Add stable event schemas and local durable storage for per-ticket/per-run metrics.
   - This is the dependency for dashboard analytics, cloud cost accounting, smarter routing, and later Omnigraph memory.

2. **Dashboard analytics and write-control parity**
   - Use the current LiveView dashboard as the first operator surface.
   - Make conversations readable/writable when authenticated and feature-enabled.
   - Add cost-per-ticket, token-per-ticket, model/backend, outcome, runtime, and rate-limit visibility.

3. **Role / skill presets and context budgets**
   - This gives immediate token savings and reduces agent prompt bloat.

4. **Typed direct messaging on the existing event bus**
   - Keep the first pass internal to Aiur. Avoid importing A2A/CrewAI/LangGraph just to message between Aiur-owned agents.

5. **Cloud worker adapter**
   - Introduce a remote-worker boundary but keep the local runner as the default implementation.
   - Then spike AWS ECS/Fargate or AWS Batch with one cloud worker per ticket.

6. **Omnigraph write-first memory sink**
   - Once events and run summaries are stable, write them into Omnigraph.
   - Add retrieval into prompts only after there is a useful corpus and good provenance.

## 3. Current Aiur Dashboard / Observability Spike

### 3.1 What already exists

Aiur is not starting from zero. Current repo/docs show:

- Aiur runs autonomous coding agents against tracker work, creates isolated workspaces, launches Codex or Claude, drives repeated turns, and cleans up when work reaches a terminal state.
- The CLI already shows active agents and lets an operator open an agent chat pane, pause/resume, and send messages.
- The LiveView dashboard at `/` mirrors the active-agent surface in read-only mode by default.
- Dashboard browser write controls can be enabled early with `observability.dashboard_writable: true`.
- When `server.port` or CLI `--port` is set, Aiur exposes the LiveView dashboard and `/api/v1/*` JSON read endpoints; agent-write endpoints are disabled unless dashboard writability is enabled.

Current code surfaces reviewed:

- `AiurWeb.DashboardLive`
  - Subscribes to observability updates.
  - Shows running count, retrying count, total tokens, input/output tokens, runtime, upstream rate-limit snapshot, running sessions, retry queue, and a per-agent log modal.
  - The log modal can show parsed agent messages.
  - If `dashboard_writable?()` is true, the modal exposes a message composer plus `Pause` and `Send` actions.
  - It calls `Aiur.AgentChat.send/2` and `Aiur.AgentChat.pause/1`.

- `AiurWeb.Router`
  - Uses a dashboard auth pipeline with optional Basic Auth via `AIUR_DASHBOARD_USERNAME` / `AIUR_DASHBOARD_PASSWORD`.
  - Protects JSON write endpoints with same-origin/referrer checks and `X-Aiur-Request: 1`.
  - Keeps dashboard write endpoints behind `observability.dashboard_writable`.
  - Exposes read routes for `/api/v1/state` and `/api/v1/:issue_identifier`.

- `AiurWeb.Presenter`
  - Projects orchestrator snapshots into dashboard/API payloads.
  - Includes live running/retrying state and token totals.

- `Aiur.HttpServer` / application startup behavior
  - Dashboard is local-first by default.
  - Headless/background mode skips interactive UI and dashboard unless a positive dashboard port is explicitly configured.
  - Non-loopback dashboard exposure is guarded; the server refuses unsafe non-loopback exposure without auth.

### 3.2 What the dashboard does not appear to have yet

The dashboard has useful live observability, but it does **not** yet look like a durable analytics/control product. The missing pieces are:

1. **Historical per-ticket ledger**
   - Current payloads are live snapshots. To answer “what did this ticket cost?” or “how much has this project cost this week?”, Aiur needs a durable run ledger.

2. **Cost attribution**
   - Token totals exist, but model pricing, vendor costs, cloud/container runtime cost, and cost reconciliation are not yet first-class.

3. **First-class conversation threads**
   - The log modal can read local agent logs, and writable mode can send/pause, but there is not yet a dedicated operator-visible inbox/thread model for agent-to-agent and operator-to-agent messages.

4. **Dashboard-authenticated write UX**
   - Writability exists behind a flag, but a production-ready dashboard needs explicit authenticated sessions or API tokens, write audit logs, and role/permission boundaries.

5. **PR/issue label controls**
   - Aiur’s setup wizard already creates lifecycle, complexity, model, pause/watch, and remote-control labels, but the dashboard does not yet appear to be a first-class label/routing console.

6. **Usage/rate-limit reconciliation**
   - The dashboard can display a latest upstream rate-limit snapshot when available, but it does not yet integrate provider usage/cost APIs into historical analytics or scheduling.

7. **Multi-host / cloud worker visibility**
   - Payloads already contain fields such as worker/session metadata, but there is not yet a worker-fleet page showing local vs remote workers, queue depth, cloud task IDs, task runtime, infra cost, cancellation status, or logs by host.

## 4. Pillar G — Visualization, Analytics, and Dashboard Control

### 4.1 Problem

Aiur can run agents, but the operator needs a higher-quality control and analytics plane:

- How much did this ticket cost?
- Which tickets are burning tokens?
- Which model/backend is cheaper or more reliable for this repo?
- Are Claude or Codex close to rate/token limits?
- Which tickets are stuck in repeated failure loops?
- Which agents are talking to each other?
- Which PR labels should be applied to route future work?
- What is the total cost of a project including model tokens and cloud compute?

### 4.2 Goal

Make the dashboard the operational cockpit for Aiur:

- Live view of active agents.
- Historical cost/token/runtime analytics by ticket, PR, model, repo, workflow, role, and outcome.
- Read/write agent conversations when logged in and feature-enabled.
- Label/model routing controls.
- Rate-limit and usage API awareness.
- Cloud worker and infra cost observability.

### 4.3 Recommended architecture

Add an internal boundary such as:

```elixir
defmodule Aiur.RunLedger do
  @callback record(event :: map(), opts :: keyword()) :: :ok | {:error, term()}
  @callback ticket_summary(issue_identifier :: String.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback project_summary(filters :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback recent_events(filters :: map(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
end
```

Implementations:

- `Aiur.RunLedger.Noop`
- `Aiur.RunLedger.SQLite` for local-first usage
- `Aiur.RunLedger.Postgres` later for cloud/multi-controller usage
- Optional `Aiur.RunLedger.JSONL` append-only debug sink

Suggested first storage choice:

- **SQLite for local-first v1** if the dashboard remains embedded in a single Aiur process.
- **Postgres for cloud-controller v1** if the first cloud deployment includes a persistent controller service.

Avoid making Omnigraph the primary metrics store at first. Omnigraph can receive structured events later for durable memory and graph retrieval. The dashboard needs boring, reliable analytics queries first.

### 4.4 Event model

Emit structured events at stable lifecycle points:

```json
{
  "event_id": "evt_...",
  "run_id": "run_...",
  "issue_identifier": "123",
  "repo": "owner/name",
  "kind": "turn_usage_observed",
  "agent_backend": "codex|claude",
  "model": "...",
  "role": "engineer",
  "workflow": "simple|architect_engineer_reviewer",
  "attempt": 2,
  "input_tokens": 120000,
  "output_tokens": 8000,
  "cached_input_tokens": 50000,
  "reasoning_tokens": null,
  "provider_request_id": "...",
  "started_at": "2026-07-08T12:00:00Z",
  "observed_at": "2026-07-08T12:05:00Z",
  "metadata": {}
}
```

Initial event kinds:

- `run_started`
- `workspace_created`
- `agent_selected`
- `turn_started`
- `turn_completed`
- `turn_usage_observed`
- `rate_limit_snapshot_observed`
- `operator_message_sent`
- `agent_message_sent`
- `agent_paused`
- `agent_resumed`
- `label_applied`
- `label_removed`
- `pr_opened`
- `pr_updated`
- `ci_result_observed`
- `run_completed`
- `run_failed`
- `infra_task_started`
- `infra_task_stopped`
- `infra_cost_estimated`
- `vendor_cost_reconciled`

### 4.5 Suggested tables

For SQLite/Postgres:

- `runs`
  - `run_id`, `repo`, `issue_identifier`, `issue_url`, `pr_url`, `agent_backend`, `model`, `role`, `workflow`, `status`, `started_at`, `ended_at`, `worker_kind`, `worker_ref`

- `turns`
  - `turn_id`, `run_id`, `turn_index`, `started_at`, `ended_at`, `status`, `summary`

- `usage_observations`
  - `usage_id`, `run_id`, `turn_id`, `provider`, `model`, `input_tokens`, `output_tokens`, `cached_input_tokens`, `reasoning_tokens`, `raw_usage_json`, `provider_request_id`, `observed_at`

- `cost_estimates`
  - `cost_id`, `run_id`, `scope`, `currency`, `amount`, `basis`, `confidence`, `observed_at`
  - `scope` examples: `model_tokens`, `cloud_compute`, `storage`, `egress`, `total_estimate`, `vendor_reconciled`

- `rate_limit_snapshots`
  - `snapshot_id`, `provider`, `model`, `limit_type`, `limit_value`, `remaining_value`, `reset_at`, `raw_headers`, `observed_at`

- `messages`
  - `message_id`, `thread_id`, `run_id`, `issue_identifier`, `sender`, `recipient`, `subject`, `body`, `urgency`, `expects_reply`, `status`, `created_at`, `acknowledged_at`

- `labels`
  - `event_id`, `issue_identifier`, `pr_identifier`, `label`, `action`, `actor`, `source`, `created_at`

- `infra_tasks`
  - `task_id`, `run_id`, `provider`, `service`, `region`, `container_image`, `vcpu`, `memory_mb`, `ephemeral_storage_gb`, `started_at`, `stopped_at`, `exit_code`, `status`, `raw_task_ref`

### 4.6 Provider usage and rate-limit integrations

#### OpenAI / Codex side

Use two sources:

1. **Live request/response accounting**
   - Capture usage from each model response and response headers where available.
   - Capture OpenAI rate-limit headers such as remaining requests/tokens and reset timing.
   - This is the best signal for real-time scheduling and concurrency control.

2. **Admin Usage / Costs API reconciliation**
   - Use OpenAI’s organization usage and cost endpoints to reconcile aggregate usage, group by project/API key/model, and build historical charts.
   - Treat this as delayed/bucketed reconciliation, not as the only real-time throttling signal.

#### Anthropic / Claude side

Use three sources depending on product path:

1. **Live API headers / usage**
   - Anthropic rate limits are tracked by requests per minute, input tokens per minute, and output tokens per minute.
   - Capture `anthropic-ratelimit-*` headers and `retry-after` when available.

2. **Usage and Cost Admin API**
   - Use Anthropic’s Usage & Cost Admin API for historical organization usage and cost reporting when using Claude API through Claude Console.

3. **Claude Code local usage**
   - Claude Code’s local `/usage` can show session token/cost estimates, but authoritative billing should come from Console/API reporting where available.

### 4.7 Cost attribution policy

Add a clear confidence model:

- `exact` — provider returns request-level cost or exact billable usage tied to the run.
- `estimated` — Aiur calculates cost from captured tokens and a configured price catalog.
- `reconciled` — vendor cost API confirms aggregate cost for a provider/model/project/API key bucket.
- `allocated` — aggregate vendor/cloud spend is proportionally allocated to tickets based on usage.

Dashboard should label all costs with confidence. Do not present allocated estimates as exact per-ticket billing.

### 4.8 Dashboard pages / UI slices

Recommended dashboard structure:

1. **Overview**
   - Active agents, retrying agents, total tokens today, estimated cost today, active cloud workers, current rate-limit headroom, recent failures.

2. **Tickets**
   - Table grouped by issue/ticket/PR.
   - Columns: status, agent backend, model, role/workflow, turns, runtime, token usage, estimated model cost, estimated infra cost, PR status, last event.

3. **Ticket detail**
   - Timeline of runs, attempts, turns, messages, tests, labels, PR events, cost breakdown, log links, worker task ref.

4. **Conversations**
   - Operator-to-agent and agent-to-agent threads.
   - Read/write when logged in and dashboard writability is enabled.
   - Support ack/reply/status, not just raw log display.

5. **Costs**
   - Cost by day/week, repo, model, backend, workflow, role, ticket, outcome.
   - Separate model-token cost from cloud-infra cost.
   - Show estimated vs reconciled cost.

6. **Rate limits / usage**
   - Latest OpenAI/Anthropic rate-limit snapshots.
   - Provider usage buckets from admin APIs.
   - Concurrency recommendations or warnings.

7. **Workers**
   - Local and remote workers.
   - Worker status, host/provider, run ID, CPU/memory/storage config, elapsed time, cost estimate, logs, cancel action.

8. **Routing / labels**
   - Apply/remove routing labels such as `model:*`, `complexity:*`, `agent:paused`, `agent:todo`, `agent:watch`, and role/workflow labels if added.
   - Show why Aiur selected Claude vs Codex and which labels influenced routing.

9. **Memory / patterns** later
   - Omnigraph-derived recurring failure patterns, repeated fixes, refactor signals, and similar prior issues.

### 4.9 Dashboard write controls

Current writable controls are a good start, but production-ish dashboard control needs:

- Explicit login/session model, not only optional Basic Auth.
- `observability.dashboard_writable` still off by default.
- Role-gated actions: read-only, operator, admin.
- Audit log for every write action.
- Same-origin/custom-header protections retained for JSON endpoints.
- No provider admin keys or cloud credentials exposed to the browser.

Initial write actions:

- Send operator message to running agent.
- Pause/resume agent.
- Refresh/retry issue.
- Apply/remove labels to issue/PR.
- Set preferred backend/model/role/workflow for issue.
- Cancel/requeue remote worker.

### 4.10 Minimal v1

A realistic v1 dashboard analytics pass:

1. Add `Aiur.RunLedger` with SQLite storage.
2. Record `run_started`, `turn_usage_observed`, `run_completed`, `run_failed`, and `operator_message_sent`.
3. Add cost estimates from a static provider/model price catalog.
4. Add ticket-level dashboard page with:
   - total tokens,
   - estimated model cost,
   - runtime,
   - turns,
   - current status,
   - model/backend,
   - log link/modal.
5. Harden dashboard writability for operator message + pause/resume only.
6. Add feature flags:

```yaml
observability:
  dashboard_writable: false
  analytics_enabled: true
  ledger:
    provider: sqlite
    path: .aiur/aiur.db
  cost_estimates:
    enabled: true
    price_catalog: .aiur/model_prices.yaml
```

### 4.11 Acceptance criteria

- Existing dashboard still works without analytics enabled.
- A completed local run creates a queryable run ledger row.
- A ticket detail page shows total tokens and estimated cost.
- Dashboard makes clear whether costs are estimated or reconciled.
- Writable controls remain disabled unless explicitly configured.
- Every dashboard write action is audit-logged.
- No provider admin keys are sent to the browser.

## 5. Pillar H — Cloud / Containerized Execution

### 5.1 Problem

Local execution on a NUC/MacBook can hit practical limits around 8–10 parallel agents. For larger projects, such as 100 tickets, options are currently awkward:

- Run Aiur on multiple local machines and coordinate manually or through GitHub.
- Overload one machine.
- Reduce parallelism and wait.
- Build a new abstraction where each agent run is containerized and cloud-executed, while preserving communication and observability.

### 5.2 Goal

Let one Aiur controller dispatch many isolated agent workers to cloud infrastructure, while still providing:

- central dashboard,
- central run ledger,
- centralized messages/events,
- per-worker logs,
- model token cost,
- cloud infra cost,
- cancellation/retry,
- final GitHub/PR outcomes,
- optional Omnigraph memory writes.

### 5.3 Current Aiur constraint to preserve

Aiur’s existing `workspace.bootstrap_image` is a cache-seeding mechanism, not full agent containerization: the warm image seeds missing build caches into `/workspace`, but agents/opencode still run on the host. Cloud execution needs a new remote-worker abstraction rather than assuming the existing bootstrap-image feature is already a worker runtime.

### 5.4 Recommended architecture: controller + workers

Use a controller/worker model.

```text
┌────────────────────────────────────────────────────────────┐
│ Aiur Controller                                             │
│ - tracker polling                                           │
│ - scheduling / routing                                      │
│ - dashboard / API                                           │
│ - run ledger                                                │
│ - event bus / direct messages                               │
│ - provider usage/rate-limit state                           │
│ - remote worker lifecycle                                   │
└───────────────┬────────────────────────────────────────────┘
                │ start worker / stream events / send control
                ▼
┌────────────────────────────────────────────────────────────┐
│ Aiur Worker Container                                       │
│ - one issue/ticket run                                      │
│ - repo checkout / workspace                                 │
│ - before_run hooks                                          │
│ - selected backend: Codex or Claude                         │
│ - logs and usage emitted back to controller                  │
│ - final branch/PR pushed to GitHub                           │
└────────────────────────────────────────────────────────────┘
```

Key design choice:

- Agents should **not** need direct peer-to-peer network access.
- They should communicate through the controller: event bus, direct-message tools, dashboard-visible threads, and later Omnigraph memory.

This preserves a single coordination surface and avoids distributed-agent chaos.

### 5.5 New execution boundary

Add an internal behavior such as:

```elixir
defmodule Aiur.AgentRunner do
  @callback start_run(issue :: map(), plan :: map(), opts :: keyword()) ::
              {:ok, worker_ref :: map()} | {:error, term()}

  @callback send_message(worker_ref :: map(), text :: String.t(), opts :: keyword()) ::
              {:ok, request_id :: String.t()} | {:error, term()}

  @callback pause(worker_ref :: map(), opts :: keyword()) ::
              {:ok, request_id :: String.t()} | {:error, term()}

  @callback resume(worker_ref :: map(), opts :: keyword()) ::
              {:ok, request_id :: String.t()} | {:error, term()}

  @callback cancel(worker_ref :: map(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback snapshot(worker_ref :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
```

Implementations:

- `Aiur.AgentRunner.Local` — current behavior.
- `Aiur.AgentRunner.RemoteStub` — fake worker for tests.
- `Aiur.AgentRunner.ECSFargate` — starts one ECS/Fargate task per run.
- `Aiur.AgentRunner.AWSBatch` — submits one AWS Batch job per run.
- Later: `Aiur.AgentRunner.CloudRunJobs`, `Aiur.AgentRunner.AzureContainerApps`, etc.

### 5.6 Worker container contract

Create a separate worker image and entrypoint:

```bash
aiur-worker \
  --run-id "$AIUR_RUN_ID" \
  --issue-id "$AIUR_ISSUE_ID" \
  --controller-url "$AIUR_CONTROLLER_URL" \
  --assignment-token "$AIUR_ASSIGNMENT_TOKEN"
```

Worker responsibilities:

1. Authenticate to controller.
2. Fetch assignment payload.
3. Clone or restore repository workspace.
4. Run `before_run` hooks.
5. Launch selected agent backend with issue prompt/config.
6. Stream logs/events/usage to controller.
7. Poll for control messages at safe turn boundaries.
8. Push branch and open/update PR when run succeeds.
9. Upload final artifacts/logs.
10. Exit with a meaningful status code.

### 5.7 Pause/resume in cloud

Local Aiur pause is cooperative and safe-turn-boundary-based. Cloud workers should start with the same semantics:

- v1: cooperative pause at safe turn boundaries.
- v1: cancel/requeue is allowed.
- v1: no full container hibernation/snapshotting.
- v2: consider durable worker state or phase-level restart if needed.

Do not promise arbitrary mid-token interruption across remote providers and containers. Keep pause semantics explicit and capability-advertised in the dashboard.

### 5.8 Workspace and cache strategy

Options:

1. **Ephemeral workspace per worker**
   - Simplest and safest.
   - Clone repo each run or use shallow/partial clone.
   - Persist final branch/PR, logs, and run ledger; discard workspace.

2. **Prebuilt worker image with toolchains and dependencies**
   - Good for faster startup.
   - Rebuild image when repo/toolchain changes.

3. **Shared persistent filesystem cache**
   - AWS EFS can provide shared persistent storage for ECS/Fargate or Batch jobs.
   - Useful for large dependency/build caches, but adds filesystem complexity and possible concurrency issues.

4. **Object storage cache**
   - S3/GCS/Azure Blob for logs/artifacts/cache tarballs.
   - More explicit and often easier to reason about than a shared filesystem.

Recommended first pass:

- Use ephemeral workspace plus prebuilt worker image.
- Persist logs/artifacts to controller storage or object storage.
- Add EFS/S3 cache only after measuring clone/build overhead.

### 5.9 Hosting options

#### Option A — AWS ECS/Fargate RunTask

Best first implementation if the goal is a straightforward serverless-container worker:

- Controller runs as local process or ECS service.
- Controller calls ECS `RunTask` for each ticket.
- Each task gets isolated CPU/memory/network boundary.
- Fargate avoids managing EC2 hosts.
- Fargate task ephemeral storage defaults to 20 GiB and can be increased up to 200 GiB.
- EFS can be added later for shared persistent caches.
- ECS Exec can be added later for debugging remote workers.

Recommendation: **best v1 cloud-worker spike** if Aiur wants minimum infrastructure surface while proving the remote-runner abstraction.

#### Option B — AWS Batch

Best for 100-ticket campaigns and queued finite work:

- AWS Batch is designed to plan, schedule, and run containerized batch workloads.
- Batch can use ECS, EKS, Fargate, Spot, On-Demand, and EC2 resources.
- It gives queues, retry policies, priorities, compute environments, and scaling knobs.

Recommendation: **best longer-term AWS fit** if Aiur’s workload becomes “submit 100 independent finite issue jobs with max concurrency and retry policy.”

A practical path is:

1. Implement the remote-runner behavior using ECS/Fargate RunTask.
2. Reuse the same worker image/contract for AWS Batch.
3. Switch scheduling from direct RunTask to Batch SubmitJob when queue/retry/cost controls matter.

#### Option C — ECS on EC2 / ECS Managed Instances

Best if Fargate constraints become painful:

- Large repos or very high build-cache I/O.
- Need cheaper high-utilization compute.
- Need custom host-level debugging or larger local disks.
- Need GPUs or specific CPU architectures.

Recommendation: defer until Fargate/Batch has proven the product value or until local filesystem/I/O constraints force it.

#### Option D — Google Cloud Run Jobs

Good serverless-container alternative:

- Cloud Run Jobs run finite container tasks.
- Jobs can retry failed tasks and support long task timeouts up to 168 hours.
- Scales well for stateless workers.

Recommendation: good if the project is already on GCP or wants a very simple serverless job model. It may be less natural than ECS/Batch for interactive debugging and persistent workspace semantics.

#### Option E — Azure Container Apps Jobs

Good if already on Azure:

- Jobs run finite-duration containerized tasks and stop.
- Jobs can be manual, scheduled, or event-driven.
- Apps and jobs share environment-level networking/logging.

Recommendation: viable Azure equivalent, but not the default unless the user’s infra is already Azure.

#### Option F — Fly.io Machines

Good for fast prototypes and lightweight remote workers:

- Fly uses Docker images as packaging but runs them inside lightweight VMs.
- Fly Machines expose a simple REST API and launch quickly.
- Fly Volumes can provide local persistent storage.

Recommendation: good developer-experience option, but less ideal as the primary 100-worker fleet/cost-accounting platform than AWS Batch/ECS.

#### Option G — Kubernetes / EKS

Powerful but likely overkill now:

- Good if Aiur becomes a multi-tenant platform.
- Good if you already have Kubernetes operations.
- Adds more cluster/network/storage/IAM complexity than needed for the first cloud spike.

Recommendation: do not start here.

### 5.10 Cloud cost analytics

Cloud execution should feed the same run ledger:

```json
{
  "kind": "infra_task_stopped",
  "run_id": "run_...",
  "provider": "aws",
  "service": "ecs_fargate",
  "region": "us-west-2",
  "task_ref": "arn:aws:ecs:...",
  "vcpu": 2,
  "memory_mb": 8192,
  "ephemeral_storage_gb": 50,
  "started_at": "2026-07-08T12:00:00Z",
  "stopped_at": "2026-07-08T12:42:00Z",
  "exit_code": 0,
  "estimated_cost_usd": 0.73
}
```

Cost layers:

- model token cost,
- cloud compute cost,
- storage/cache cost,
- network/egress cost,
- total ticket cost.

For AWS, tag resources/tasks where possible with:

- `aiur:run_id`
- `aiur:issue`
- `aiur:repo`
- `aiur:agent_backend`
- `aiur:model`
- `aiur:workflow`

Use local estimates immediately, then reconcile with cloud billing/cost allocation reports later. AWS cost allocation tags can help organize costs, but they must be activated and can be delayed before appearing in billing reports.

### 5.11 Security model

Cloud execution increases risk. Minimum requirements:

- Worker assignment tokens scoped to one run.
- Secrets injected at task/job level, not baked into images.
- Separate GitHub token scope for workers.
- Provider API keys scoped by project/workspace if possible.
- Controller validates every worker event against run assignment.
- No worker can read every run’s logs by default.
- Dashboard write endpoints remain auth-gated.
- Central audit log for operator actions and worker lifecycle events.
- Kill switch: stop scheduling remote workers and fall back to local runner.

### 5.12 Minimal v1 cloud spike

1. Add `Aiur.AgentRunner` behavior with `Local` implementation preserving current behavior.
2. Add `RemoteStub` for tests.
3. Build worker image that can run one issue in a container.
4. Add controller API endpoints for:
   - fetch assignment,
   - append logs/events,
   - append usage observations,
   - heartbeat,
   - complete/fail run,
   - poll control messages.
5. Implement `ECSFargate` or `AWSBatch` runner.
6. Run one cloud worker against one low-risk test issue.
7. Stream logs to dashboard.
8. Record infra task start/stop and estimated infra cost in run ledger.
9. Add dashboard “Workers” card/page.

### 5.13 Acceptance criteria

- Local Aiur behavior remains the default.
- One issue can be executed by a remote worker container.
- Logs/events from the remote worker appear in the controller dashboard.
- The worker can push branch / open or update PR using scoped credentials.
- Controller can cancel/requeue a remote run.
- Per-ticket cost includes model cost plus estimated infra cost.
- Worker crash is visible and does not crash controller.
- Remote execution can be disabled by config.

## 6. Updated Cross-Pillar Architecture

### 6.1 Shared event spine

All pillars should use the same event spine:

```text
Agent lifecycle → structured event → run ledger → dashboard/API
                                      ↘ optional memory sink → Omnigraph
                                      ↘ optional analytics export
```

Do not create one event schema for dashboard, another for Omnigraph, another for cloud, and another for messaging. Define one internal event vocabulary and adapt it outward.

### 6.2 Local-first, cloud-optional

Every feature should have a local-mode story:

- Run ledger works with SQLite.
- Dashboard analytics works locally.
- Agent runner defaults to local.
- Cloud runner is a config-selected implementation.
- Omnigraph is optional.
- External provider usage APIs are optional and used for reconciliation.

### 6.3 Avoid premature framework replacement

LangGraph, CrewAI, A2A, MCP, and Omnigraph are useful reference points, but they should not replace Aiur’s current orchestration in the first pass.

- **LangGraph** — reference for stateful role/workflow orchestration.
- **CrewAI** — reference for roles/crews/tasks.
- **A2A** — later interop protocol if Aiur talks to external opaque agents.
- **MCP** — later tool/context interface for exposing Aiur controls externally.
- **Omnigraph** — memory/dev-graph backend, not the primary dashboard metrics database.

## 7. Updated Roadmap

### Phase 0 — Metrics / Run Ledger Contract

Tasks:

- Define run/event IDs.
- Add event schemas.
- Add SQLite run ledger.
- Capture run start/end/failure.
- Capture per-turn token usage where available.
- Capture model/backend/role/workflow.
- Add cost-estimate interface with static price catalog.

Exit criteria:

- Current behavior unchanged.
- A completed run produces a durable row/queryable summary.
- Dashboard can fetch historical ticket metrics.

### Phase 1 — Dashboard Analytics + Writable Parity

Tasks:

- Add ticket detail page.
- Add cost/token/runtime summaries.
- Add conversation thread page or improved log modal.
- Harden `dashboard_writable` with audit logging.
- Add pause/resume/send message controls.
- Add label/model routing controls if GitHub adapter supports it cleanly.

Exit criteria:

- Operator can answer “what did this ticket cost?”
- Operator can read/write agent conversation from dashboard when authenticated and enabled.
- Writes are audit-logged and disabled by default.

### Phase 2 — Role / Skill Presets + Context Accounting

Tasks:

- Role config.
- Prompt-section token accounting.
- Role-specific skills.
- Manual role selection.
- Basic architect/engineer/reviewer workflow.

Exit criteria:

- Specialized roles use less prompt budget than the all-skills default.
- Existing single-agent engineer flow remains default.

### Phase 3 — Direct Messaging on Existing Event Bus

Tasks:

- Typed direct-message event.
- Persistent inbox/thread storage.
- `aiur_message_agent` and `aiur_read_inbox` tools.
- Turn-boundary message digest.
- Dashboard/CLI conversation view.

Exit criteria:

- Agents can message each other without raw event hacks.
- Operator can inspect conversations.
- Messages survive restart.

### Phase 4 — Remote Worker Boundary

Tasks:

- Add `Aiur.AgentRunner` behavior.
- Local runner preserves current behavior.
- Remote stub test runner.
- Worker container entrypoint.
- Controller APIs for worker assignment/logs/heartbeat/completion.

Exit criteria:

- Architecture supports remote workers without actually requiring cloud.
- Tests can exercise remote-worker lifecycle.

### Phase 5 — AWS Cloud Worker Spike

Tasks:

- Build worker image.
- Implement ECS/Fargate RunTask or AWS Batch SubmitJob runner.
- Run one real test ticket remotely.
- Stream logs to controller.
- Record infra task metadata and cost estimate.
- Add dashboard workers page.

Exit criteria:

- One remote cloud ticket completes and opens/updates PR.
- Dashboard shows remote worker state and cost estimate.
- Remote failure is visible and recoverable.

### Phase 6 — Usage API / Rate-Limit Aware Scheduling

Tasks:

- Capture provider rate-limit headers.
- Add periodic OpenAI usage/cost reconciliation.
- Add periodic Anthropic usage/cost reconciliation where applicable.
- Add dashboard rate-limit headroom page.
- Add conservative routing/concurrency hints.

Exit criteria:

- Dashboard shows live-ish headroom and historical provider usage.
- Scheduler can avoid obviously exhausted provider/model routes.
- Ticket costs can be reconciled or labeled estimated/allocated.

### Phase 7 — Omnigraph Write-First Memory Sink

Tasks:

- Define memory schema from run ledger events.
- Write summaries/failures/decisions/files/tests/PR outcomes to Omnigraph.
- Add CLI/debug query for similar failures.
- Keep prompt injection disabled.

Exit criteria:

- Completed runs become queryable durable memory.
- Similar-failure query works.
- Aiur continues if Omnigraph is offline.

### Phase 8 — Memory Retrieval + Smarter Routing

Tasks:

- Inject bounded memory context into prompt builder.
- Add `aiur_memory_search` tool.
- Use recurring failure/refactor signals for architect-first routing.
- Surface memory/patterns in dashboard.

Exit criteria:

- Agents get useful prior context for recurring issues.
- Memory context has provenance and confidence.
- Operator can disable it.

## 8. V1 Cutline Recommendation

A strong near-term implementation target that includes the two new pillars without over-engineering:

1. `Aiur.RunLedger` behavior + SQLite implementation.
2. Event capture for run start/end/failure and token usage.
3. Dashboard ticket analytics page:
   - total tokens,
   - estimated model cost,
   - runtime,
   - turns,
   - model/backend,
   - status/outcome.
4. Dashboard conversation parity for current local agents:
   - read parsed log,
   - send operator message,
   - pause/resume,
   - write audit log.
5. `Aiur.AgentRunner` behavior with current local runner implementation.
6. `RemoteStub` runner for tests.
7. Worker-container design doc / Dockerfile skeleton.
8. AWS ECS/Fargate spike behind config, but only one-ticket smoke test.

Do **not** include in the first PR:

- full 100-agent cloud scheduler,
- Omnigraph prompt retrieval,
- Kubernetes,
- LangGraph import,
- multi-tenant auth,
- precise cloud billing reconciliation,
- automatic model switching based only on delayed usage APIs.

## 9. Implementation Questions for the Agent

- Where should the local ledger live: repo `.aiur/aiur.db`, global `~/.aiur/aiur.db`, or configurable?
- Does the current refactor change orchestrator snapshot shape or agent lifecycle callbacks?
- Where is the cleanest event hook for token usage: backend adapter, orchestrator turn loop, presenter, or agent log parser?
- Does Codex/Claude usage come through API responses, CLI logs, provider bridge, or all of the above?
- Should dashboard write auth remain Basic Auth for v1, or add session login/API tokens immediately?
- Which GitHub adapter APIs already support applying/removing labels from issues and PRs?
- What is the smallest remote-worker contract that preserves local runner behavior?
- Does worker container need opencode panes, or only logs/messages?
- What credentials are needed inside a worker: GitHub token, provider API key, controller assignment token, repo SSH key?
- Should remote workers push branches directly, or send patches/artifacts back to the controller?
- Is the first cloud target ECS/Fargate RunTask or AWS Batch SubmitJob?
- Is persistent shared cache worth it, or should v1 use ephemeral workspace plus prebuilt image?

## 10. Source Notes

Primary sources reviewed for this update:

### Aiur

- Aiur README: `https://github.com/its-everdred/aiur/blob/main/src/README.md`
- Dashboard LiveView: `https://raw.githubusercontent.com/its-everdred/aiur/main/src/lib/aiur_web/live/dashboard_live.ex`
- Dashboard router/API gates: `https://raw.githubusercontent.com/its-everdred/aiur/main/src/lib/aiur_web/router.ex`
- Presenter: `https://raw.githubusercontent.com/its-everdred/aiur/main/src/lib/aiur_web/presenter.ex`
- Observability API controller: `https://raw.githubusercontent.com/its-everdred/aiur/main/src/lib/aiur_web/observability_api_controller.ex`
- HttpServer: `https://raw.githubusercontent.com/its-everdred/aiur/main/src/lib/aiur/http_server.ex`

### Provider usage / rate limits

- OpenAI rate limits: `https://developers.openai.com/api/docs/guides/rate-limits`
- OpenAI Usage/Costs API cookbook: `https://developers.openai.com/cookbook/examples/completions_usage_api`
- Anthropic rate limits: `https://platform.claude.com/docs/en/api/rate-limits`
- Anthropic Usage & Cost Admin API: `https://platform.claude.com/docs/en/manage-claude/usage-cost-api`

### Cloud/container execution

- AWS ECS/Fargate ephemeral storage: `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-storage.html`
- AWS Batch Fargate compute environments: `https://docs.aws.amazon.com/batch/latest/userguide/fargate.html`
- AWS Batch overview: `https://docs.aws.amazon.com/batch/latest/userguide/what-is-batch.html`
- Amazon ECS/EFS storage options: `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_data_volumes.html`
- Amazon ECS EFS volumes: `https://docs.aws.amazon.com/AmazonECS/latest/developerguide/efs-volumes.html`
- AWS cost allocation tags: `https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html`
- Google Cloud Run Jobs: `https://docs.cloud.google.com/run/docs/create-jobs`
- Azure Container Apps Jobs: `https://learn.microsoft.com/en-us/azure/container-apps/jobs`
- Fly.io Docker/images model: `https://fly.io/docs/blueprints/working-with-docker/`
- Fly Machines overview: `https://fly.io/docs/machines/overview/`
- Fly Volumes: `https://fly.io/docs/volumes/overview/`
