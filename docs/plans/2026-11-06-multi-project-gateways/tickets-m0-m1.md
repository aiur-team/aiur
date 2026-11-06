# Tickets: M0 contracts and M1 durable ownership

Part of [the plan](../2026-11-06-multi-project-gateways.md). GitHub titles are the `###` headings, without the plan id.
Each body starts with `Plan id: MPG-<n>`. Each implementation ticket carries its research deep dive (`MPG-<n>R`,
label `kind:research`), which blocks it. The research acceptance is the same for every deep dive:

> **Research acceptance.** `docs/research/MPG-<n>.md` exists, follows the research-spike template, and contains:
> (1) the design, (2) exact paths, module, function and config names, (3) test scenarios with expected values,
> (4) open questions, each with a recommended default. It names every file the implementation ticket will touch.

Acceptance checks marked **[fails without]** must fail on `main` before the change and pass after it.

---

## M0 — Contracts

### Expose the gateway identity on every daemon response

- Plan id: MPG-001 · `lane:gateway-cli` · complexity 1 · depends on: MPG-001R
- **Outcome.** Every control result, heartbeat and status report carries `gateway_id` (the machine id) and
  `gateway_label`.
- **Next action.** Create `src/lib/aiur/gateway/identity.ex` with `Aiur.Gateway.Identity.current/0` returning
  `%{gateway_id: machine_id, gateway_label: machine_label}` from `Aiur.Identity.machine/0`.
- **Files.** `src/lib/aiur/gateway/identity.ex` (new); `src/lib/aiur_web/controllers/control_controller.ex`
  (add both keys beside `instance_id`); `src/lib/aiur/orchestrator/instance_heartbeat_metadata.ex`;
  test `src/test/aiur/gateway/identity_test.exs`, `src/test/aiur_web/controllers/control_controller_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** A control call response JSON contains `gateway_id` equal to the fixture `identity.json` id.
  - [ ] With no `identity.json`, the response carries `gateway_id: null` and `gateway_identity: "unavailable"`, never a made-up id.
- **Non-goals.** Renaming `instance_id`; the registry (MPG-201).
- **Serializes with.** MPG-204 (`control_controller.ex`); merge MPG-001 first.
- **Research MPG-001R** (complexity 1). Confirm the two existing identity schemes (`Aiur.Identity.instance_id/0`
  and `Aiur.Instance.Identity`) and record which callers must keep `instance_id`.

### Add projects, capacity and coordination sections to the machine config

- Plan id: MPG-002 · `lane:multi-project` · complexity 2 · depends on: MPG-002R
- **Outcome.** `~/.aiur/machine` accepts `projects:`, `capacity:` and `coordination:` and rejects unknown keys in
  them, using the existing schema pattern. Nothing reads them yet.
- **Next action.** Add `src/lib/aiur/machine/settings/schema/projects.ex`, `capacity.ex`, `coordination.ex` and list
  them in `Aiur.Machine.Settings` (`defstruct` and the `Map.take` key list).
- **Shape** (plan section "State schemas", S3).
- **Files.** the three schema files; `src/lib/aiur/machine/settings.ex`; `src/lib/aiur/machine/settings/schema.ex`;
  test `src/test/aiur/machine/settings_test.exs`; docs `website/docs-app/reference/configuration-daemon.md`
  (one `machine:` entry per key, checked by `scripts/check-config-docs.py`).
- **Acceptance.**
  - [ ] **[fails without]** A file with `projects: [{repo: "o/r", config: "/abs/.aiur/config", max_agents: 4}]` loads with those values.
  - [ ] `projects[].repo` without a slash, a relative `config` path, or `capacity.max_agents: 0` returns `{:error, {:invalid, ...}}` naming the key.
  - [ ] The existing `mobile`, `gateway`, `pairing`, `transport` sections still load unchanged.
- **Research MPG-002R** (complexity 1). Final key names and defaults; how `config:` paths stay private (the file is mode 0600 and outside Git).

---

## M1 — Durable ticket ownership

### Characterise GitHub ref compare-and-set for ticket ownership

- Plan id: MPG-101 · `lane:ownership` · complexity 2 · kind: spike (no research ticket) · depends on: none
- **Outcome.** A committed characterisation note and test script that record, against a sandbox repository, what
  GitHub returns for each candidate claim primitive. It picks the ref namespace for KTD-2.
- **Next action.** Write `scripts/spikes/github_ownership_cas.sh` that, with a token for a sandbox repository:
  1. creates a tree and commit holding `owner.json`;
  2. calls GraphQL `updateRefs` with `beforeOid` all zeros on `refs/aiur/owners/1`, twice;
  3. advances the ref with a correct and a stale `beforeOid`;
  4. repeats steps 2-3 on `refs/heads/aiur-owner/1`;
  5. repeats with REST `POST /git/refs` and `PATCH force=false`;
  6. reads the ref back with and without caching headers.
- **Files.** `scripts/spikes/github_ownership_cas.sh` (new); `docs/research/MPG-101.md` (results).
- **Acceptance.**
  - [ ] `docs/research/MPG-101.md` records status code, error type and message for each of the six steps, and the date.
  - [ ] It states one chosen namespace and the exact "lost the race" signature the adapter must match, and lists every other response as "unknown".
  - [ ] The script exits non-zero if the second create in step 2 succeeds.
- **Stop rule.** If no namespace gives an atomic create-if-absent, stop and report; do not start MPG-102.

### Read and write ticket ownership refs through the GitHub client

- Plan id: MPG-102 · `lane:ownership` · complexity 3 · depends on: MPG-101, MPG-102R
- **Outcome.** `Aiur.Ownership.GitHubRef` reads, claims, transfers and releases the ownership record (S1) with
  compare-and-set only, and classifies every response as `:won`, `:lost` or `:unknown`.
- **Next action.** Create `src/lib/aiur/ownership/github_ref.ex` with `read/2`, `claim/3`, `transfer/4`,
  `release/3`. Every write sends `beforeOid` (the observed head, or zeros for a first claim).
- **Files.** `src/lib/aiur/ownership/github_ref.ex`, `src/lib/aiur/ownership/record.ex` (new); reuse
  `src/lib/aiur/github/transport/graphql.ex` and `src/lib/aiur/github/client.ex`; tests
  `src/test/aiur/ownership/github_ref_test.exs`, `src/test/aiur/ownership/record_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Two concurrent `claim/3` calls against the stub that applies `beforeOid` atomically give exactly one `{:won, record}` and one `{:lost, current}`.
  - [ ] A stub timeout after the write returns `{:unknown, :timeout}`, never `:won`.
  - [ ] A 422 whose message is not the MPG-101 "lost" signature returns `{:unknown, {:http, 422, msg}}`.
  - [ ] `claim/3` and `transfer/4` both write `epoch = previous_epoch + 1`, including a claim of a `released` ticket; a stale `beforeOid` returns `:lost`.
  - [ ] The record carries `daemon_key` (the instance key) beside `gateway_id`.
  - [ ] Ownership reads bypass `Aiur.GitHub.ReadCache` (test asserts no cache lookup).
- **Research MPG-102R** (complexity 2, depends on MPG-101). Request shapes, the tree/commit write sequence, budget
  attribution through the GitHub budget broker, and the `owner.json` encoder.

### Require durable ownership before every dispatch

- Plan id: MPG-103 · `lane:ownership` · complexity 3 · depends on: MPG-102, MPG-103R
- **Outcome.** With `instance.ownership: github`, a ticket starts only if this gateway owns it or wins its claim.
  PR-anchored units claim `pr-<N>`. The two lease bypasses are gone.
- **Next action.** In `src/lib/aiur/orchestrator/dispatcher/shared_lease_dispatch.ex`, call a new
  `Aiur.Ownership.ensure_owned/2` after the Capacity admit check (`GatewayDemand.admit/2`, MPG-402) and before `dispatch_with_shared_lease`, for every issue including `pr_head_ref` ones.
- **Files.** `src/lib/aiur/ownership.ex` (new facade); `shared_lease_dispatch.ex` (remove the `pr_head_ref` branch at
  lines 67-73); `src/lib/aiur/agent_runner.ex` (remove lines 27-30 bypass); `src/lib/aiur/config/schema/instance.ex`
  (key `ownership: off | github`, default `off`); tests `src/test/aiur/orchestrator/ownership_dispatch_test.exs`;
  docs `website/docs-app/reference/configuration-daemon.md`.
- **Acceptance.**
  - [ ] **[fails without]** Two orchestrators in one test, sharing the atomic stub, poll the same todo ticket: exactly one agent starts.
  - [ ] **[fails without]** A PR-anchored unit owned by another gateway is not dispatched.
  - [ ] **[fails without]** Two daemons with the same `gateway_id` and different `daemon_key` on one repository: only the claimant dispatches.
  - [ ] A ticket Capacity denies makes no ownership reads or writes (claim runs after `admit/2`).
  - [ ] `:unknown` ownership declines dispatch with attention `ownership_unknown` and retries next poll.
  - [ ] With `instance.ownership: off`, the existing `shared_lease_dispatch_test.exs` passes unchanged.
- **Research MPG-103R** (complexity 2, depends on MPG-101). Every caller of `do_dispatch_issue` and
  `dispatch_prevalidated_issue` (11 listed in `code-evidence.md` §2), and whether each needs ownership.

### Project ownership as a gateway label and skip ambiguous tickets

- Plan id: MPG-104 · `lane:ownership` · complexity 2 · depends on: MPG-103, MPG-104R
- **Outcome.** An owned ticket carries `gateway:<label-slug>`. When ref and label disagree, or the ref is unreadable,
  the ticket is skipped and one alert names it.
- **Next action.** Add `Aiur.Ownership.Projection.reconcile/2` and call it after every `:won` claim and once per poll
  for owned tickets.
- **Files.** `src/lib/aiur/ownership/projection.ex` (new); `src/lib/aiur/github/labels.ex`; alert topic in
  `src/lib/aiur/alerts/`; tests `src/test/aiur/ownership/projection_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Ref says PC, no label: the PC daemon adds `gateway:pc`.
  - [ ] **[fails without]** Ref says Nook, label says `gateway:pc`: neither daemon dispatches; alert `system.ownership.ambiguous` fires once per ticket per hour.
  - [ ] A label with no ref on a ticket with no state label is treated as a human assignment request and logged, not dispatched.
- **Research MPG-104R** (complexity 1, depends on MPG-101). Label colour and creation, alert dedupe key, budget cost.

### Stop a stale owner before pushes and pull requests

- Plan id: MPG-105 · `lane:ownership` · complexity 3 · depends on: MPG-103, MPG-105R
- **Outcome.** An agent whose ticket was transferred away cannot push, open a PR or request a merge. Its daemon
  stops it, keeps the workspace and alerts.
- **Next action.** Add a git guard fragment `src/priv/github_guard/git/20-ownership-fence.sh` that asks the daemon
  for the ticket's owner and epoch, and refuses `push` on mismatch. Add the same check to the `gh` guard for
  `pr create` and `pr merge`.
- **Files.** the fragment; `src/lib/aiur/agent_github_guard/script.ex` (`@parts`); `src/priv/github_guard/parts.tsv`;
  `src/lib/aiur/github/agent_budget_socket.ex` (owner query); `src/lib/aiur/ownership/fence.ex` (new);
  tests `src/test/aiur/ownership/fence_test.exs`, `src/test/aiur/agent_github_guard/` guard test.
- **Acceptance.**
  - [ ] **[fails without]** An agent started at epoch 3 tries `git push` after the ref moved to epoch 4: the guard exits non-zero with `ownership moved`.
  - [ ] The daemon checks the ref at most 30 s before each fenced call; a cached read older than 30 s is refreshed.
  - [ ] Fence query failure refuses the push (fail closed) and says why.
- **Research MPG-105R** (complexity 2, depends on MPG-101). Socket protocol, where the agent's epoch is recorded at
  spawn, and which `gh` subcommands count as irreversible.

### Show and transfer ticket ownership from the CLI

- Plan id: MPG-106 · `lane:ownership` · complexity 3 · depends on: MPG-102, MPG-001, MPG-205, MPG-106R
- **Outcome.** `aiur ticket owner <n>` prints owner, epoch, actor and age. `aiur ticket assign <n> --to <gateway>
  --reason <text>` transfers with compare-and-set (`--to`, not `--gateway`, which selects the gateway the command
  runs on). It refuses a live owner unless a human forces it locally. An owner with no liveness source (store down
  and hello unreachable) counts as live. A transfer disables auto-merge on the old owner's open PR.
- **Settled.** Q3: the proposed default stands (Kevin did not object; not his decision).
- **Next action.** Add `owner` and `assign` verbs to `packaging/npm/aiur-cli/libexec/engine/ticket.sh` and their RPC
  functions to `src/lib/aiur/ownership/cli.ex`; allowlist `owner` as `read`, `assign` as category `tickets`.
- **Files.** `engine/ticket.sh`; `src/lib/aiur/ownership/cli.ex` (new); `src/lib/aiur/control_call/allowlist.ex`;
  tests `src/test/aiur/ownership/cli_test.exs`, `packaging/npm/aiur-cli/test/launcher-ticket-owner.test.mjs`;
  docs `website/docs-app/reference/cli-operations.md`.
- **Acceptance.**
  - [ ] **[fails without]** `aiur ticket assign 12 --to nook --reason x` on a PC-owned ticket whose owner heartbeat is older than `coordination.offline_after_seconds` writes epoch+1 with `actor.kind` set.
  - [ ] With the store down and PC's hello unreachable, the same command exits 64 `owner liveness unknown; treat as online`.
  - [ ] After a transfer, the old owner's PR has auto-merge disabled (stub asserts the call).
  - [ ] Assigning away from a live owner without `--force` exits 64 with `owner is online; ask it to release`.
  - [ ] `--force` over `--gateway`/`--instance` (remote) or with `--as` is refused: forced transfer is local and human only.
- **Research MPG-106R** (complexity 1, depends on MPG-101). Liveness sources (heartbeat, hello), JSON output shape.

### Migrate today's label prefixes to ownership records

- Plan id: MPG-107 · `lane:ownership` · complexity 2 · depends on: MPG-102, MPG-104, MPG-107R
- **Outcome.** `aiur ownership migrate --map agent=<gateway> --map nuc=<gateway> [--apply]` writes an owner ref
  for each open ticket whose state labels name exactly one mapped prefix, and reports the rest as ambiguous.
- **Next action.** Add `src/lib/aiur/ownership/migration.ex` with `plan/1` (pure: labels in, actions out) and
  `apply/2`.
- **Files.** `src/lib/aiur/ownership/migration.ex`, `cli.ex`; `engine/` dispatch entry; test
  `src/test/aiur/ownership/migration_test.exs`; docs `website/docs-app/reference/cli-operations.md`.
- **Acceptance.**
  - [ ] **[fails without]** `plan/1` on `[agent:todo]`, `[nuc:in-progress]`, `[agent:todo, nuc:done]`, `[]` returns claim PC, claim Nook, ambiguous, skip.
  - [ ] Dry run (no `--apply`) performs zero GitHub writes (stub asserts).
  - [ ] Re-running `--apply` performs zero writes (idempotent).
  - [ ] Writes are paced by the GitHub budget broker; the report prints the number of writes.
- **Research MPG-107R** (complexity 1, depends on MPG-101). Count the live population of open tickets per prefix
  pattern (state the date and count, per AGENTS.md item 5).

### Make the Postgres lease an optimisation under durable ownership

- Plan id: MPG-108 · `lane:ownership` · complexity 3 · depends on: MPG-103, MPG-108R
- **Outcome.** With ownership on, a gateway dispatches its own tickets with no lease store, and `instance.owns` no
  longer holds dispatch when the store is absent. With the store present, the run lease still prevents two runs.
- **Next action.** In `src/lib/aiur/instance.ex` `eligible?/3`, return `:eligible` for a ticket whose ownership
  record names this gateway before any roster check.
- **Files.** `src/lib/aiur/instance.ex`; `src/lib/aiur/orchestrator/dispatcher/shared_lease_dispatch.ex`;
  `src/lib/aiur/instance/dispatch_claim.ex`; tests `src/test/aiur/instance_test.exs`,
  `src/test/aiur/orchestrator/shared_lease_dispatch_test.exs`.
- **Acceptance.**
  - [ ] **[fails without]** Store unset, `owns` set, ticket owned by self: dispatch proceeds (today it holds as `:unavailable`).
  - [ ] Store down, ticket unowned: claim on GitHub decides, no `ownership_unknown` hold.
  - [ ] Store up: a second run of an owned ticket while the first renews its lease is refused.
  - [ ] **[fails without]** Store unset, ownership on, `instance.role: secondary`: landing watch, main watch and the quarantine lifter do not start (today every primary starts them).
- **Research MPG-108R** (complexity 2, depends on MPG-101). Every reader of `Instance.foreign?/skip?` (11 observers in
  `code-evidence.md` §2) and whether durable ownership replaces the roster for each.

### Prove two daemons share one repository without duplicate work

- Plan id: MPG-109 · `lane:acceptance` · complexity 3 · depends on: MPG-103..108, MPG-109R
- **Outcome.** Live evidence on PC and Nook (still one daemon per repository) for acceptance tests A1, A5 and A6
  in the plan.
- **Next action.** Run the MPG-109R script after deploying with `instance.ownership: github` on both gateways.
- **Acceptance.**
  - [ ] 30 minutes of simultaneous dispatch on one repository: zero tickets with two agent runs (query the analytics store and both transcripts).
  - [ ] Stop the shared Postgres: both gateways keep dispatching their own tickets; neither dispatches the other's.
  - [ ] Stop Nook's daemon: PC skips every Nook-owned ticket. (The offline alert is checked in MPG-701.)
- **Research MPG-109R** (complexity 2, depends on MPG-101). Write `docs/research/MPG-109.md` as a step-by-step runbook with the queries
  that count duplicates and the expected numbers.
