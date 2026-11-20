# Multi-project gateways: code evidence

Companion to [the plan](../2026-11-06-multi-project-gateways.md). It checks each code claim in the scope against the
repository at commit `d5c58c4ae1` (origin/main on 2026-11-06). Line numbers refer to that commit. Abbreviations:
`E/` = `packaging/npm/aiur-cli/libexec/`, `EE/` = `E/engine/`, `S/` = `src/lib/`.

Status words: **confirmed** (the code says so), **corrected** (the scope or briefing said something different),
**not verifiable here** (needs a live machine; deployment state is out of this document's reach).

---

## 1. Scope claims, checked

| # | Scope claim | Status | Evidence |
|---|---|---|---|
| 1 | Remote commands merged | confirmed | `POST /api/v1/control` (`S/aiur_web/routes/control.ex:8-12`, `S/aiur_web/controllers/control_controller.ex`); `aiur --instance <name> <cmd>` (`E/aiur-engine.sh:212-234`, `EE/remote.sh`). PR #5994. |
| 2 | Executor merged wakes, not live-proven | code confirmed; live proof not verifiable here | `aiur --instance all executor-wait` fans out with one ack cursor per instance (`EE/remote_all.sh:98-318`, PR #6358). Each daemon keeps its own journal (`S/aiur/executor/state_paths.ex`). |
| 3 | Claims merged, not deployed | code confirmed; deployment not verifiable here | Postgres ticket lease `INSERT ... ON CONFLICT DO UPDATE ... WHERE expires_at <= now - grace OR instance_id = EXCLUDED.instance_id` (`S/aiur/instance/lease_store.ex:197-220`, PR #5991). Off unless `AIUR_LEASE_DATABASE_URL` is set (`lease_store.ex:52-54`, `S/aiur/instance/dispatch_claim.ex:14`). |
| 4 | `instance.owns` / `instance.pool` merged | confirmed | Schema `S/aiur/config/schema/instance.ex:61-67`; rule order `S/aiur/instance.ex:174-212`. Peers' rules travel in Postgres heartbeats, so `owns` holds dispatch when the store is absent (`S/aiur/orchestrator/dispatcher/shared_lease_dispatch.ex:98-101`). PR #6170. |
| 5 | Stream Deck switcher merged | confirmed | `packages/streamdeck/src/instance-switcher.ts:10-112`; targets come from the same `~/.aiur/remote-instances.yaml` registry (`packages/streamdeck/src/instances.ts:108-113`). PRs #6931, #7043. |
| 6 | `/instances` roster merged, no full live data | confirmed | Route `S/aiur_web/routes/dashboard_pages.ex:55`; reads Postgres `aiur_instances` (`S/aiur/instance/lease_store.ex:270-330`). Heartbeat publishes only `owns`, `pool`, `dispatching` (`S/aiur/instance.ex:223-237`), so `agent_count`, `agent_capacity`, `held_tickets`, `public_url` render unknown (`S/aiur/instance/roster.ex:85-91`). PR #6310. |
| 7 | #5938 parked | confirmed | Open, `nuc:parked`: one hosted entry point for many repositories. |
| 8 | #5974 parked | confirmed | Open, `agent:parked`: live two-instance proof of leases, ownership and leader failover (capstone of #5964). |
| 9 | PR #6902 background only | confirmed | Open, unmerged requirements-only plan; its gap list includes "PR-anchored dispatch skips the lease" and "lease is per run". |
| 10 | Keep-agents PRs #7529, #7548, #7564 | **corrected** | These are issues. The PRs are #7534, #7553 and #7569, all merged 2026-11-06. See section 6. |
| 11 | "Open-PR rework path that skips claims" | **corrected (narrower)** | Only PR-anchored units (open PRs whose head is not an Aiur ticket branch) skip the lease: `shared_lease_dispatch.ex:67-73` and `S/aiur/agent_runner.ex:27-30`. Ordinary rework on an Aiur ticket with an open PR goes through the lease and `ReworkDispatchClaim` (`S/aiur/orchestrator/dispatcher/launch.ex:167-184`). |
| 12 | ~134 files read single-repo config | **measured: 142** | Files calling `Aiur.Config.settings*`; 229 files touch settings, tracker repo or workspace root. Commands in section 5. |
| 13 | ~1,470 single-orchestrator references | **measured: 1,487 tokens, 181 to the singleton** | 1,487 counts every `Aiur.Orchestrator` token including about 265 submodules; 181 name the singleton; 140 calls route to it. |
| 14 | ~41 GB of machine state | not verifiable here | A live-machine measurement; out of scope for a public document. |
| 15 | Daemon restart costs 20+ minutes of dispatch on ~130 tickets | not verifiable here | Briefing estimate; the capstone measures it (MPG-701). |
| 16 | Two machines use `agent:` and `nuc:` prefixes without enforced separation | **partly corrected** | Prefixes come from `github.label_prefix` (`S/aiur/github/config.ex:11,160-175`). A cross-prefix guard skips any ticket that carries another prefix's state label (`S/aiur/github/state_labels.ex:23-38`, `S/aiur/orchestrator/dispatch_policy.ex:385-403`, PR #5925). Separation exists for well-labelled tickets; nothing is atomic. |
| 17 | Khala external mode carries full conversations | not verifiable here | Khala is outside this repository. |

---

## 2. Ticket ownership today

- **No GitHub ownership record.** No assignee, comment or body marker names an owner. The only GitHub "claim" is the
  state label `<prefix>:in-progress`.
- **The label write is read-then-write.** `S/aiur/github/issue_state.ex:104-245` reads the issue, compares labels,
  re-reads with an ETag (free 304), then adds the new label and removes the old. The POST/DELETE carry no
  precondition; `grep -i if-match` finds nothing. `StateWriteCoordinator` uses `:global.trans`
  (`S/aiur/github/state_write_coordinator.ex:8-10`), which locks inside one Erlang cluster only.
- **Todo claims are written after the agent starts** (`S/aiur/orchestrator/dispatcher/launch.ex:298,328-338`;
  `S/aiur/orchestrator/todo_dispatch_claim.ex:122-178`); a failed write only logs.
- **Rework claims are written before the agent starts** and decline on failure
  (`S/aiur/orchestrator/rework_dispatch_claim.ex:40-93`).
- **The Postgres lease covers one run, not the ticket's life.** Renewal stops when the worker exits and the row expires
  (`S/aiur/instance/lease_store/renewal.ex:39-40`). TTL 30 s, renewal 10 s, margin 5 s, takeover grace 20 s
  (`lease_store.ex:12-15`). Ticket key `owner/repo#N`, without the label prefix (`lease_store/ticket_key.ex:63-67`).
- **Fail-closed with a store, fail-open without one.** Store loss raises `system.instance.ownership_unknown` and holds
  dispatch (`lease_store.ex:457-468`); no store returns `:disabled` and dispatch proceeds
  (`S/aiur/instance/dispatch_claim.ex:14`).
- **Repository leader.** Without a store every primary runs landing watch, main watch and the quarantine lifter
  (`S/aiur/instance/repository_leader.ex:71-76`; `S/aiur/application/children.ex:375-385`).
- **Tests.** A real two-process lease race exists but is skipped without a database
  (`src/test/aiur/instance_lease_store_test.exs:179-226`). No test races two daemons on the GitHub label write.

---

## 3. CLI surface and `--instance`

### 3.1 How `--instance` works

- Must be the first argument (`E/aiur-engine.sh:212-224`; `scripts/aiurdev:47-59`). A leaked
  `AIUR_REMOTE_INSTANCE` is cleared first. Names match `^[A-Za-z0-9._-]+$` (`EE/remote.sh:5-12`); `all` is reserved.
- A remote instance is a named HTTPS origin plus a token reference in `~/.aiur/remote-instances.yaml`
  (`EE/remote.sh:93-95,139,181,248-328`). Plain HTTP only for loopback; token file mode 0600 or `token_env: AIUR_TOKEN_*`.
- Transport: `POST <url>/api/v1/control` with a bearer token, body
  `{contract:"aiur.control.call", contract_version:1, expression, command, timeout_ms, max_scope}`
  (`EE/remote.sh:377-497`). The result carries `instance_id` and `build{version,commit}`
  (`control_controller.ex:137-146`).
- `--instance all` accepts read commands only, forces `max_scope=read` and fans out in parallel (`EE/remote_all.sh:10-88,391-420`).
  Text output prints `== name (host) ==` per target; `--json` prints one line per target; the exit code is the highest.
- Error exits (`EE/remote.sh:445-494`): unreachable 69, token rejected 77, write scope missing 77, unsupported on that
  build 64, refused 64, timeout with unknown outcome 124.
- The local "instance" is a different thing: the daemon keyed by
  `AIUR_INSTANCE_KEY = sha256(project root)[0:10]` (`EE/identity.sh:198-212`), node
  `aiur-$USER-<key>@127.0.0.1` (`EE/identity.sh:228`). Its `instance_id` is `<machine_id>/<instance_key>`
  (`S/aiur/identity.ex:23-28`).

### 3.2 Server side

- Parser: `ControlCall.parse(expr, remote: true)` walks literals only, no eval (`S/aiur/control_call.ex:32-58`).
- Allowlist: `{function, arity, scope or classifier, positional, keyword constraints}`
  (`S/aiur/control_call/allowlist.ex:49-257`). Unknown functions return `unknown_on_build`.
- Scopes: token `read|write`; a write needs token write, requested write and `dashboard_writable`
  (`control_controller.ex:49,62`). Remote arguments may not carry `who`, `actor`, `set_by`, `owner`, `env`
  (`control_call.ex:110-119`).
- Audit: `control-audit.ndjson` with `at, token, scope, call, expression_sha256, outcome, exit_code, elapsed_ms,
  remote_ip` (`S/aiur/control_call/audit.ex:8-13`; `control_controller.ex:123-135`). Writes, refusals, timeouts and
  auth failures are audited; successful reads are not. A failed audit write returns 503.
- Idempotency: none at the transport level. Only `operator_relay_answer`, `command_request` and `executor_answer`
  take an `idempotency_key`, some with `expected_version` (`allowlist.ex:115-152`). A timed-out write is audited
  `timeout_unknown` and left running (`control_call.ex:164-166`).
- Tokens: `aiur token create <name> --scope read|write`; `aiur_<base64url 32 bytes>`, sha256 stored in
  `client-tokens.json` (`S/aiur/client_tokens.ex:10-25,67-71`).

### 3.3 Inventory

Transport: **RPC** = Erlang distribution locally, HTTPS control call with `--instance`; **EVAL** = local one-shot;
**local** = machine processes, files or tmux. Remote column: **yes** = `--instance` gate accepts it; **all** = also
`--instance all`; **refused** = gate refuses it; **gap** = server allowlists it but the gate refuses it.

| Namespace / command | Target | R/W | Transport | Remote | Entry |
|---|---|---|---|---|---|
| bare, `run`, `--bg`, `--container` | daemon | W | local (tmux, BEAM) | refused | `E/aiur-engine.sh:185,283-288,470-486`; `EE/run.sh:43` |
| `stop`, `restart [--keep-agents]` | daemon | W | local + RPC handoff | refused ("local to the host") | `EE/lifecycle.sh:166`; `EE/restart.sh:147` |
| `init`, `--version`, `help` | repo / client | W / R | EVAL | refused | `EE/oneshot.sh:3,18` |
| `doctor`, `upgrade`, `cleanup-stale` | machine | R/W | local | refused | `E/aiur-mise-doctor`; `EE/upgrade.sh:125`; `EE/commands.sh:309` |
| `pre-pr`, `pr merge` | repo / PR | W | git, GitHub API, deny-scoped RPC | refused | `EE/pre_pr.sh`; `S/aiur/pr_merge_cli.ex:7` |
| `login`, `logout`, `accounts` | machine accounts | W / R | EVAL; `accounts` RPC | refused; `accounts` all | `EE/oneshot.sh:36-90`; `EE/usage.sh:64-81` |
| `token create\|list\|revoke` | daemon state file | W | EVAL | refused | `S/aiur/client_tokens_cli.ex` |
| `findings`, `ask`, `asks` | repo / daemon | R/W | EVAL / RPC (not allowlisted) | refused | `EE/oneshot.sh:185-235` |
| `status [--handoff]`, `agents`, `units` | daemon / agents / tickets | R | RPC | all | `EE/commands.sh:40-61,245`; `EE/report_commands.sh:5` |
| `build-orders`, `analytics`, `github-cost`, `github-usage` | project / budget | R | RPC | all | `EE/report_commands.sh:51-164` |
| `usage`, `ticket-usage`, `capabilities` | machine / ticket | R | RPC | all | `EE/usage.sh:3,84`; `E/aiur-capabilities.sh:2` |
| `alerts [ack]`, `executor-sweep [--apply]`, `watch` | daemon | R; W for ack/apply/watch default | RPC | yes; all for read forms | `EE/report_commands.sh:183-217` |
| `listen`, `executor-listen` | daemon events | R (stream) | held RPC | refused | `EE/report_commands.sh:257` |
| `history`, `voice transcripts` | daemon | R | RPC (not allowlisted) | refused | `EE/history.sh`; `EE/voice.sh:3` |
| `pause`, `resume` (global or ids), `park` | daemon / agents | W | RPC | yes | `EE/commands.sh:77-101` |
| `take`, `release`, `reset-budget`, `workspace-recover` | ticket / workspace | W | RPC | yes | `EE/commands.sh:137-173` |
| `redispatch` | ticket | W | RPC | **gap** | `EE/commands.sh:104`; `allowlist.ex:193` |
| `message <id>`, `message --status`, `listen-mode` | agent / ticket | W / R | RPC | yes; all for `--status` | `EE/commands.sh:184-239,402` |
| `set <key>`, `set --list`, `--todo` | daemon settings / queue | W / R | RPC; `set` sends local `caller_cwd` | yes | `EE/commands.sh:332-397`; `EE/oneshot.sh:166` |
| `queue show\|order\|add\|set\|...` | project queue | R / W | RPC | yes; all for show | `E/aiur-queue.sh:12,112` |
| `ticket estimate` | ticket | R / W | RPC | **gap** | `EE/ticket.sh:2,47`; `allowlist.ex:113-114` |
| `lane`, `epic`, `feature` | project | R / W | RPC | yes; all for show/list | `E/aiur-lane.sh:57`; `E/aiur-epic.sh:104`; `E/aiur-feature.sh:123` |
| `experiments <verb>` | daemon | R / W | RPC | yes; all for read verbs | `E/aiur-experiments.sh:44` |
| `command`, `commands`, `command request` | Decisions | R / W | RPC, idempotency key on request | yes | `EE/command_request.sh:2-126` |
| `operator-relay-answer` | Decisions | W | RPC | **gap** | `EE/executor_commands.sh:139`; `allowlist.ex:115` |
| `answer --operator` | Decisions | W | RPC, TTY confirm | refused | `EE/executor_commands.sh:85` |
| `executor-ack\|answer\|escalate\|reclassify\|moot` | Decisions | W | RPC | yes | `EE/executor_commands.sh:9-289` |
| `executor-wait\|claim\|release\|fast-forward` | wake stream | W | RPC; `--as` required | yes; wait has its own all fan-out | `EE/executor_commands.sh:292-405`; `EE/remote.sh:84-89` |
| `executor-revoke\|emit\|subscribe\|unsubscribe` | wake stream | W | RPC | yes | `EE/executor_commands.sh:408-444` |
| `executor-subscriptions\|roster\|session` | wake stream | R | RPC | all | `EE/executor_commands.sh:336,448` |
| `executor-attach\|detach` | local harness hooks | W | local + RPC deny | refused | `E/aiur-executor-session.sh:45-73` |
| `aiurdev build`, `--test`, `--test3`, `--clear` | dev checkout | W | local, mix | not applicable | `scripts/lib/aiurdev-harness.sh:59-242` |
| mix tasks `aiur.*`, `lint`, `pr_body.check` | dev checkout | R/W | local | not applicable | `src/lib/mix/tasks/` |

Findings that shape the plan:

1. A selector that targets another daemon over HTTPS already exists; `--gateway` reuses it (KTD-6).
2. Three commands are allowlisted on the server but refused by the CLI gate (`redispatch`, `ticket estimate`,
   `operator-relay-answer`); MPG-203 closes the gap.
3. `set` sends the caller's working directory, which means nothing on another machine; MPG-311 replaces it with
   `--project`.
4. Write tokens are all-or-nothing: any write token can call every write in the allowlist, including
   `executor-revoke` and `set`. MPG-205 adds categories.

---

## 4. Config and identity

- Discovery: `<cwd>/.aiur/config`, legacy `<cwd>/.aiurconfig` (rejected), `~/.aiur/config`, legacy `~/.aiurconfig`
  (`S/aiur/workflow.ex:59-96`). A global config takes its repo from the cwd's `origin` (`S/aiur/github/config.ex:13-24`).
- One config per VM: `Aiur.WorkflowStore` (registered singleton, `S/aiur/workflow_store.ex:53`) publishes one ETS
  entry; `Aiur.Config.settings/0` reads it with a per-process memo (`S/aiur/config.ex:57-104`). There is a
  per-process override for the workflow file path (`S/aiur/workflow.ex:25-38`), the seam MPG-302 uses.
- Machine settings: `~/.aiur/machine`, YAML, mode 0600, sections `mobile`, `gateway` (the paired-phone listener's
  host, port and endpoints), `pairing`, `transport` (`S/aiur/machine/settings.ex:13-23,96`;
  `S/aiur/machine/settings/schema/gateway.ex`). Nothing outside `S/aiur/machine/` reads it yet.
- Machine identity: `identity.json` with a 26-character base32 `machine_id` and a `machine_label`
  (`S/aiur/identity/store.ex:34-41`); a durable Ed25519 machine key exists but signs nothing yet
  (`S/aiur/machine/store.ex:1-6`, PR #6806).
- Shared-store instance id: `instance.id`, or `hostname:sha256(state_dir)[0:8]` (`S/aiur/instance/identity.ex:17-44`).
  This differs from `Aiur.Identity.instance_id/0`; two identity schemes exist today.

## 5. Single-repo and singleton measurements

Run from `src/` (ugrep). Full commands and the per-category table are reproducible with:

| Measure | Command (abridged) | Result |
|---|---|---|
| `.ex` files under `lib` | `find lib -name '*.ex' \| wc -l` | 2,768 (415,833 lines) |
| files calling `Aiur.Config.settings*` | alias-aware `grep -rlE` over `settings(!\|(\|_uncached)` | 142 (311 call sites) |
| files reading the tracker section | `grep -rlE '\.tracker\.(repo\|project_slug\|owner\|kind\|github\|linear)'` | 45 |
| files reading workspace root | `grep -rlE 'workspace\.root\b\|\bworkspace_root\b'` | 38 |
| files naming the repo by other routes | union of `GitHub.Config.repo`, `repo_slug`, `Tracker.project_identity`, `Paths.repo_name` | 91 |
| union of the above | `sort -u` of the lists | 229 |
| `Aiur.Orchestrator` tokens | `grep -rhoE '\bAiur\.Orchestrator\b'` | 1,487 in 383 files |
| the singleton only | `grep -rhoP '\bAiur\.Orchestrator\b(?!\.[A-Z])(?!\.\{)'` | 181 in 97 files |
| calls into the singleton | `grep -rhoP '(?<![\w])(Aiur\.)?Orchestrator\.[a-z_]+[!?]?'` | 130 in 65 files |
| hard-coded `GenServer.call(Orchestrator` / `whereis` | `grep -rhoE '(GenServer\.(call\|cast)\|Process\.whereis)\(\s*(Aiur\.)?Orchestrator\b'` | 10 in 9 files |
| default arguments naming the orchestrator | `grep -rhoE '\\\\ (Aiur\.)?Orchestrator\b\|, (Aiur\.)?Orchestrator\)'` | 32 |
| other `name: __MODULE__` singletons | `grep -rlE 'name: __MODULE__'` | 27 files |

Counts are file-level regex counts, accurate to about 5 %.

Other single-project facts:

- The orchestrator state struct has no repo, project or tracker field (`S/aiur/orchestrator/state.ex:246-383`).
- Tracker adapters are modules chosen from global `tracker.kind` (`S/aiur/tracker.ex:302-303`); callbacks take no
  repo argument (`S/aiur/tracker/issue_tracker.ex:11-44`). `Aiur.TrackerIdentity` is a repo-qualified identity seam.
- `max_concurrent_agents` caps one daemon (`S/aiur/orchestrator/slots.ex:205-226,348-372`). Heartbeat
  `agent_count`/`agent_capacity` keys are display-only and not published today.
- Daemon state lives under `<state root>/<instance_key>/<project leaf>/` (`S/aiur/config/paths.ex:448-481`), with
  per-project leaves for the build queue, features, conversations and usage. The per-project split exists on disk.
- Build Orders are GitHub issues labelled `build-order` with sub-issues, scoped to the configured repo
  (`S/aiur/build_order/github_graph/settings.ex:40-41`). The Build Queue is a local JSON file
  (`S/aiur/build_queue/store.ex:75-78`). Feature order is `build_order.feature_order`, a list with no numeric priority
  (`S/aiur/config/schema/build_order.ex:80`); ticket priority is the `priority:N` label.
- Global pause is per daemon in `<decision_state_dir>/global-pause.json`, survives restart and stays paused when
  unreadable (`S/aiur/orchestrator/global_pause_store.ex:5-46,85-95`).

## 6. Agents across a daemon restart

- PRs #7534, #7553, #7569 give every backend a handoff mode: `relay` (codex, claude), `repl` (the tmux pane survives),
  `in_daemon` (OpenAI-compatible, conversation serialised at a step boundary).
- `Aiur.Handoff.prepare/1` holds dispatch and snapshots runners (`S/aiur/handoff.ex:16-46`). The record is
  `<runtime_state_dir>/handoff/current.json`, valid 30 minutes (`S/aiur/handoff/record.ex:14-23,76`).
- On boot `Adopter.adopt/0` runs before the first poll, checks a config fingerprint (tracker kind, repo, Linear slug,
  `workspace.root`, `worker.ssh_hosts`), takes a slot, and inserts adopted ids into `running` and `claimed`
  (`S/aiur/orchestrator/lifecycle.ex:174`; `S/aiur/handoff/adopter.ex:14-132`; `S/aiur/handoff/compatibility.ex:7-16`).
- Gaps for this plan: the record and fingerprint are per daemon, so in a multi-project daemon one project's config
  change would fall back every agent (MPG-308). Handoff is same-machine only, which the scope does not ask to change.

## 7. Dashboard and auth

- Phoenix runs inside the daemon (`S/aiur/http_server.ex:124-165`). Host allowlist: `server.public_url`,
  `server.allowed_hosts`, endpoint hosts; `*.ts.net` only while bound to loopback (`S/aiur_web/host_allowlist.ex`).
- No CORS anywhere. Write APIs require same-origin plus `X-Aiur-Request: 1` (`S/aiur_web/router.ex:95-106`).
- Browser auth: session from Google sign-in or passkeys, Basic Auth for machines on loopback only
  (`S/aiur_web/financial_data_access.ex:51-91`; `S/aiur_web/client_token_auth.ex:39-40`).
- The public website is a simulation and calls no daemon API (`website/src/dashboard.ts:1`).
- Home `/` and `/build` render `AiurWeb.BuildLive` (`S/aiur_web/live/build_live.ex`).
