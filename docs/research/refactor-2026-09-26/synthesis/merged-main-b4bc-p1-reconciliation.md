# P1 review disagreements at `main@b4bc11f`

Two independent follow-up reviewers inspected the 12 IDs marked `reconcile` in
[`merged-main-b4bc-p1-dispositions.csv`](merged-main-b4bc-p1-dispositions.csv).
These are source-level reconciliations, not measured production incidence or
permission to preserve the frozen P1 severity. None of the 12 is fully fixed.

| ID | Current mechanism | Required behavior or population check |
| --- | --- | --- |
| `agent-backends-cc-01` | Narrowed: local Codex notification metadata can spawn `ps`; `codex/turn_loop.ex:153-156`, `codex/app_server_port.ex:212-225`. | Count process spawns and latency by local and remote notification path. |
| `agent-runtime-02` | Narrowed: `agent_runner/queue_drain.ex:703-784` still hard matches fallible queue calls; its restore/replacement path now has bounded confirmation. | Inject an unavailable queue at each remaining call and assert bounded, durable recovery. |
| `events-webhooks-executor-03` | Synchronous CI polling remains reachable from `orchestrator/dispatcher.ex:130-138`; `events/github_ci_poller.ex:49-75` drains tasks with per-target timeouts. Duration and fleet impact are unknown. | Block a multiple-target poll and measure status/enqueue latency. |
| `github-b-02` | Narrowed: `github/issues.ex:296-323` retains a check-then-put race; other paths use atomic update or unconditional replacement. | Interleave a newer webhook with a stale fetch and prove the store retains the newer version. |
| `loose-2-05` | Corrupt-journal failure and replay per dedupe lookup remain in `executor_events.ex:416-439`; the broad normal-path latency and notification-loss claims are unmeasured. | Test corrupt and realistically sized journals through deferred/requested publication; measure latency and visible attention. |
| `loose-2-07` | Narrowed: some failure paths use Logger or swallow subscription errors (`log_file.ex:115-126`, `current_run_projections.ex:168-174`); alternate signals exist at other sites. | Inject each cited failure under default logging and assert an operator-visible status, alert, or count. |
| `telemetry-usage-01` | `usage_ledger/counter_policy.ex:20-46` grows a durable idempotency set; `usage_ledger/store.ex:234-245` has capacity rejection. Present population and time to limit are unknown. | Count live keys and bytes, then test cap/restart behavior and visible failure. |
| `telemetry-usage-02` | Narrowed: Codex headless normalization can emit both absolute and delta token cells (`usage/headless/normalizer.ex:18-23`), which aggregate queries sum. The exact overlap and money impact are unproved. | Feed a real-shaped dual-usage payload through normalization, ledger and aggregate; assert physical totals and price. |
| `tests-1c-01` | A real Linear URL/token is the test-support default (`test/support/test_support.exs:1143-1152`), but many tests disable polling. The frozen test count does not prove outbound calls. | Run affected tests with a request spy and count attempted network calls. |
| `tests-5-01` | A lifecycle test uses literal PID 424242 with real Ownership (`test/aiur/agent_runner/session_lifecycle_test.exs:977-993`); a host signal requires a PID and identity collision. | Replace with an owned child or injected guardian and prove no signal escapes the fixture. |
| `web-occ-06` | Narrowed: a failed Command row can disappear via `operator_control_center/decision_presenter.ex:20-30`; the old aggregate rescue count is stale. | Inject row presentation failure and assert list/count consistency and a truthful error. |
| `web-rest-02` | `aiur_web/control_center_cache.ex:27-75` executes loader work inside a GenServer with infinite callers; it precedes later children under `rest_for_one`. Outage incidence is unknown. | Block and raise the real loader under supervision; measure caller latency and child restarts. |

Apply a finding only to the affected boundary after its check fails on the
implementation base. Recount live populations before retaining a P1 priority or
claiming saved time, cost, or quota.
