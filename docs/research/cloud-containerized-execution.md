# Cloud/Containerized Ephemeral Execution for Autonomous Coding Agents — Research Brief

_Part of the `research/optimization-pillars` wave. Maps to Pillar 7 (cloud/containerized execution) and Roadmap Phases 4–5 (remote-worker boundary + AWS cloud spike)._

**Research value: high** — strong convergent evidence across three independent lines (cloud-native job platforms, agent-specific sandbox vendors, and open agent frameworks) on a single emerging pattern: ephemeral, single-task, container-per-run isolation with a thin control-plane on top.

## Platform Comparison

### Serverless container job platforms

| Platform | Cold start | Max runtime | Ephemeral storage | Cost model | Cancel | Retry/queue | Secrets | Cost tagging | Observability |
|---|---|---|---|---|---|---|---|---|---|
| **AWS ECS/Fargate RunTask** | 10–90s (ENI + image pull + layer extract); sub-5s achievable with warm-ENI/zstd tricks | No hard cap | 20GB default, up to 200GB | Per-second vCPU/mem, no scale-to-zero | `StopTask` API | None native (pair w/ Batch/Step Functions) | Secrets Manager/SSM via task def | Per-task tags → Cost Explorer (clean attribution) | CloudWatch Logs/X-Ray |
| **AWS Batch (Fargate/EC2/Spot)** | Same as Fargate; EC2 path adds instance boot | No hard cap | Same as Fargate | Fargate Spot ~70% discount | Batch cancel/terminate | Native retry, up to 10 attempts, requeued to front | Same | Per-job-def tags | Batch console + CloudWatch |
| **GCP Cloud Run Jobs** | Seconds (optimized) | 10 min default, up to 168h (7d); GPU capped at 1h | Configurable | Per-second, scale-to-zero | Job/execution cancel | Default 3 retries; up to 10,000 parallel tasks; `CLOUD_RUN_TASK_INDEX` sharding | Secret Manager | Labels | Cloud Logging/Monitoring |
| **Azure Container Apps Jobs** | ~22s hello-world, 30–60s under burst | No fixed cap | Per-execution 4vCPU/8GiB (Consumption) | Consumption per vCPU/GiB-sec | Execution stop | No hard concurrency cap, capacity-bound | Key Vault refs | Azure tags | Log Analytics/App Insights |
| **Fly.io Machines** | Sub-second (Firecracker) | No cap | Volumes optional | Per-second, ~$0.0027/hr shared-CPU 256MB | Machines API stop/destroy | None native — build via FLAME pattern | App-level `fly secrets` (**not** per-run scoped) | Org/app-level only | `fly logs`/Grafana |
| **Modal (Sandboxes)** | <1s cached; sub-second GPU snapshot restore | Configurable, no hard cap | Private per-sandbox fs | Per-second, ~3× premium over base functions | `sandbox.terminate()` | Built-in autoscale queue | Modal Secrets objects | App/function name (less mature) | Dashboard + log stream API |
| **Northflank** | — | — | — | $0.01667/vCPU-hr + $0.00833/GB-hr, per-second | API | Persistent+ephemeral modes | Vault-style secret groups | — | Native dashboard |

### Agent-specific sandboxing / runners

| Platform | Isolation | Persistence model | Notable 2026 status |
|---|---|---|---|
| **E2B** | Firecracker microVM, ~150ms boot | Session-based, disposable | One of 7 native providers in OpenAI Agents SDK v2 (Apr 2026); BYOC not self-serve |
| **Daytona** | Docker + gVisor, 27–90ms provisioning | Persistent workspace by design | **Closed-source since June 2026**; blocks GPU passthrough |
| **Modal Sandboxes** | microVM | Ephemeral private fs | GPU-capable, premium priced for non-preemptible guarantee |
| **GitHub Copilot coding agent** | Isolated ephemeral GitHub Actions runner per task, restricted egress firewall, push-only to `copilot/*` branches, no self-approval | Fully ephemeral, destroyed post-task | Self-hosted runner support GA (Oct 2025) |
| **Devin (Cognition)** | One isolated cloud VM per session (shell+editor+browser), gRPC/WebSocket bridge <50ms | No cross-session state | Mature but proprietary, opaque cost model |
| **OpenHands** | `Workspace` abstraction — Local/Docker/Remote behind one interface; each agent = independent container | Event-sourced `ConversationState` + append-only `EventLog`, replay-to-resume, `PauseEvent` | Open source — **closest architectural analog to Aiur's needs** |

## Recommended v1 Target

**AWS ECS/Fargate `RunTask`**, called directly by Aiur's own controller (not AWS Batch). Rationale:
- Aiur's controller already owns the queue/ledger/retry logic — Batch's native queue would duplicate that state machine and create ambiguity about who owns retries.
- Per-task metering gives cost-per-run attribution "for free" via resource tags → Cost Explorer.
- Cold start (10–90s) is a rounding error against a 20–60 min agent run.
- Avoids locking onto an agent-sandbox vendor (Daytona went closed-source June 2026; E2B has no self-serve BYOC) — plain container compute is the more durable bet when portability and a controller-owned kill switch matter.
- **Alternative if ops overhead is unwanted:** Fly.io Machines (sub-second start, matches Aiur's existing "ephemeral pane process" mental model) — but its secrets model is app-scoped, not per-run scoped, a real security downgrade versus Fargate's task-role/Secrets-Manager pattern.

## Controller/Worker Contract

Modeled on OpenHands' event-sourced `ConversationState`/`EventLog`/`PauseEvent` pattern and Cloud Run Jobs' idempotency guidance:

- **Assignment**: controller issues a signed JWT (`run_id`, `ticket_id`, repo, branch, backend, cost cap, callback endpoint) + a scoped GitHub App installation token (single-repo, ~1hr expiry, refreshed by controller if the run overruns — mirrors Copilot coding agent's branch-prefix restriction).
- **No P2P**: worker's only outbound channel is to the controller (heartbeat + event stream); it never queries a worker registry or another worker.
- **Heartbeat**: `{run_id, status, last_event_seq, cost_so_far}` every 15s; missed 2× → controller marks stalled.
- **Log/usage streaming**: append-only structured events (action/observation pairs), resumable from last-acked seq on reconnect — controller is sole ledger of truth.
- **Safe-turn-boundary cancel**: worker checks a cancel flag only between completed tool-calls/turns (never mid-call), mirroring OpenHands' `PauseEvent` and Cloud Run's "checkpoint after a unit of work completes" rule. On cancel: flush partial log, push WIP branch or discard per policy, exit with a status distinguishing cancelled/failed/completed.
- **Idempotent completion**: terminal event carries `run_id` as idempotency key; controller dedupes any double-report.
- **Retry ownership**: platform-native retry (Batch/Cloud Run) is disabled — the controller alone decides re-dispatch, since only it knows whether a prior attempt made partial progress.

> _Aiur note:_ Aiur's local runner already has the coordination surface this contract needs (paused/resume, safe-turn-boundary pause, per-issue sessions). The remote-worker boundary is `Aiur.AgentRunner` behaviour + `Local`/`RemoteStub`/`ECSFargate` adapters — the local runner stays the default.

## Workspace/Cache Recommendation

Prebuilt base image (runtime + agent CLI + `git clone --mirror` of the target repo, refreshed weekly) plus incremental fetch at run start using `git clone --reference` against the cached mirror — cuts clone from minutes to seconds on large repos. Break-even is real: ~$42/mo storage for a 600GB cached image needs ~1,000+ saved clone-minutes/month to pay off — only worth it once repo size/run count justifies it; for small repos a shallow clone is already cheap. **Explicitly avoid shared EFS/NFS/S3 as a live workspace** — it reintroduces cross-run coupling that defeats per-run isolation; S3 is fine only as a read-only build-cache source.

> _Aiur note:_ Aiur already has a "warm base" prewarm (copy-on-write from a shared base checkout). That's the local analog of the prebuilt-image + reference-clone strategy — the cloud worker image is its cloud counterpart.

## Security Model

- Per-run scoped GitHub token (GitHub App install token, single-repo, short expiry) — never a long-lived PAT.
- Cloud credentials via OIDC-federated per-task IAM role, no static keys in image or task definition.
- Model API keys injected as task-def secrets, budget-capped per run where the provider supports it.
- Egress allowlist (GitHub, model API, package registries) mirroring Copilot coding agent's firewall.
- **Kill switch**: controller-level circuit breaker on error-rate/cost anomaly halts new cloud dispatch and reroutes to Aiur's existing local 8–10-agent pool — reusing a code path that already exists.

## Cost/Scale Notes

At ~100 concurrent 1vCPU/2GB Fargate tasks averaging 20–40 min runs, cold-start overhead is <5% of run cost — compute-seconds dominate. Fargate Spot (~50–70% savings) is a later lever, gated on the checkpoint contract being proven (2-min SIGTERM warning on interruption).

## Risks

- Cold start (10–90s) is a poor fit for tight retry loops — fine for ticket-scale runs.
- Agent-sandbox vendor immaturity (Daytona closed-source pivot, E2B no self-serve BYOC) argues against betting the architecture on an agent-specific sandbox vendor for v1.
- Platform-native retry vs controller-owned retry is a documented ambiguity class — resolve (disable platform retry) before it's discovered via an incident.
- GCP/Azure fine-grained cost-tagging depth was thinner in the docs than AWS's — flag if those become contenders.

## v1 Cutline

One real ticket, end to end: controller launches a single Fargate task via `RunTask` from a prebaked image (git mirror + CLI); injects a 1-hour scoped GitHub token + task-role-scoped secret; worker heartbeats every 15s; streams events into the existing run ledger; controller issues a mid-run cancel that the worker honors at the next turn boundary; worker reports completion exactly once via idempotency key; PR opens on the ticket branch; the task's Cost Explorer line item resolves back to `run_id` via tags. Prove this loop before scaling to 100.

## Sources
- [Taming Cold Starts on AWS Fargate](https://aws.plainenglish.io/taming-cold-starts-on-aws-fargate-the-architecture-behind-sub-5-second-task-launches-622ebd73b051)
- [AWS Batch FAQs](https://aws.amazon.com/batch/faqs/) · [Fargate compute environments](https://docs.aws.amazon.com/batch/latest/userguide/fargate.html) · [retry strategies](https://aws.amazon.com/blogs/compute/introducing-retry-strategies-for-aws-batch/) · [Fargate+Batch rationale](https://aws.amazon.com/blogs/hpc/why-use-fargate-with-aws-batch-for-serverless-batch-compute/)
- [Cloud Run Jobs task timeout](https://docs.cloud.google.com/run/docs/configuring/task-timeout) · [parallelism](https://docs.cloud.google.com/run/docs/configuring/parallelism) · [retries & idempotency](https://docs.cloud.google.com/run/docs/jobs-retries)
- [Azure Container Apps cold-start](https://learn.microsoft.com/en-us/azure/container-apps/cold-start) · [concurrency Q&A](https://learn.microsoft.com/en-us/answers/questions/3145487/using-azure-container-app-jobs-as-a-substitute-for)
- [Fly Machines](https://fly.io/machines/) · [Modal sandbox resources & pricing](https://modal.com/docs/guide/sandbox-resources) · [Northflank pricing](https://northflank.com/pricing) · [Daytona vs E2B](https://northflank.com/blog/daytona-vs-e2b-ai-code-execution-sandboxes)
- [GitHub Copilot coding agent 101](https://github.blog/ai-and-ml/github-copilot/github-copilot-coding-agent-101-getting-started-with-agentic-workflows-on-github/)
- [OpenHands Software Agent SDK paper](https://arxiv.org/html/2511.03690v1) — event-sourced conversation model, workspace abstraction, PauseEvent
- [Ken Muse — caching repos on custom runner images](https://www.kenmuse.com/blog/caching-repositories-on-github-runner-custom-images/)
- [Ephemeral OIDC credentials for CI/CD](https://www.systemshardening.com/articles/cicd/ephemeral-cloud-credentials-cicd/)
