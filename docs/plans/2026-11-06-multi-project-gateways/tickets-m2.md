# Tickets: M2 gateways and remote CLI

Part of [the plan](../2026-11-06-multi-project-gateways.md). Conventions (titles, plan ids, research acceptance,
**[fails without]**) are in [tickets-m0-m1.md](tickets-m0-m1.md). Launcher paths are under
`packaging/npm/aiur-cli/libexec/` (`engine/` = `libexec/engine/`); launcher tests are under
`packaging/npm/aiur-cli/test/`.

---

### Pin gateway identity in the remote registry

- Plan id: MPG-201 · `lane:gateway-cli` · complexity 2 · depends on: MPG-001, MPG-201R
- **Outcome.** Entries in `~/.aiur/remote-instances.yaml` may carry `gateway_id`, `label` and `tls_pin_sha256`. The
  first successful call records the remote `gateway_id`; a later response with another id is refused.
- **Next action.** Extend the awk parser in `engine/remote.sh` (around lines 93-328) to read the three optional keys,
  and compare `gateway_id` in each response before printing output.
- **Files.** `engine/remote.sh`; `engine/remote_all.sh`; `packages/streamdeck/src/instances.ts` (same parser, same
  keys, ignore unknown keys as today); tests `launcher-remote.test.mjs`, `packages/streamdeck/test/instances.test.ts`;
  docs `website/docs-app/reference/cli-options.md`.
- **Acceptance.**
  - [ ] **[fails without]** Registry pins `gateway_id: aaaa…`, server answers `bbbb…`: exit 77, stderr `gateway identity mismatch for 'nook'`.
  - [ ] An entry without `gateway_id` works as today and prints the id it saw once, with the command to pin it.
  - [ ] A registry file written by today's launcher parses unchanged in both the shell and Stream Deck parsers.
- **Research MPG-201R** (complexity 1). Whether pinning writes the file automatically (default: no; print the line).

### Add the --gateway selector to every remote-capable command

- Plan id: MPG-202 · `lane:gateway-cli` · complexity 2 · depends on: MPG-201, MPG-202R
- **Outcome.** `aiur --gateway <name|label|id|all|local> <cmd>` behaves exactly like `--instance`, resolving by
  registry name, case-insensitive label, or pinned id. `--instance` keeps working. Both together exit 64.
- **Next action.** In `aiur-engine.sh` lines 212-234, accept `--gateway` as the first argument and map it to the
  existing `AIUR_REMOTE_INSTANCE` path after resolution; mirror it in `scripts/aiurdev` lines 47-67.
- **Files.** `aiur-engine.sh`; `engine/remote.sh` (`resolve_gateway`); `scripts/aiurdev`; tests
  `launcher-remote.test.mjs`, `launcher-remote-all.test.mjs`; docs `website/docs-app/reference/cli-options.md`,
  `website/docs-app/reference/cli.md`.
- **Acceptance.**
  - [ ] **[fails without]** `aiur --gateway Nook status` calls the entry whose `label` is `Nook`.
  - [ ] `aiur --gateway local status` runs locally with no HTTP call.
  - [ ] `aiur --gateway nook --instance pc status` exits 64 with `use one of --gateway or --instance`.
  - [ ] `aiur --gateway nook stop` exits 64 with `stop is local to the gateway's host; run it there`.
  - [ ] An inherited `AIUR_REMOTE_INSTANCE` is still cleared (existing test stays green).
- **Research MPG-202R** (complexity 1). Ambiguity rules when a label matches two entries (default: exit 64 and list both).

### Close the remote command gate gaps

- Plan id: MPG-203 · `lane:gateway-cli` · complexity 2 · depends on: MPG-203R
- **Outcome.** `redispatch`, `ticket estimate` and `operator-relay-answer` work remotely. A test fails whenever a
  command whose RPC is allowlisted is missing from the gate or from an explicit local-only list.
- **Next action.** Add the three commands to `ensure_remote_command_allowed` in `engine/remote.sh` (lines 31-35), then add
  `src/test/aiur/control_call/gate_parity_test.exs` that reads the gate list and the allowlist.
- **Files.** `engine/remote.sh`; `src/lib/aiur/control_call/allowlist.ex` (add a `cli_command` field per entry);
  test above; docs `website/docs-app/reference/cli-options.md` (remote command table).
- **Acceptance.**
  - [ ] **[fails without]** `aiur --instance x redispatch 12` reaches the stub server.
  - [ ] **[fails without]** The parity test fails if a new allowlisted function has no gate entry and no local-only entry.
- **Research MPG-203R** (complexity 1). Map every allowlist entry to its CLI command (the inventory in
  `code-evidence.md` §3.3 is the start).

### Give remote writes request ids and replay-safe retries

- Plan id: MPG-204 · `lane:gateway-cli` · complexity 3 · depends on: MPG-204R
- **Outcome.** Control contract version 2 accepts `request_id` (UUIDv7). A repeated write with the same id and body
  returns the stored result without running again; the same id with another body returns 422 `request_id_reused`.
  Audit lines carry `request_id`, `origin_gateway` and `actor`.
- **Next action.** Add `src/lib/aiur/control_call/replay_store.ex` (ETS plus an append-only file under the runtime
  state dir, 24-hour retention) and consult it in `control_controller.ex` before `ControlCall.run`.
- **Files.** `replay_store.ex` (new); `src/lib/aiur_web/controllers/control_controller.ex`;
  `src/lib/aiur/control_call/audit.ex`; `engine/remote.sh` (send `request_id`, print it on exit 124 with
  `retry with --request-id <id> is safe`); tests `src/test/aiur/control_call/replay_store_test.exs`,
  `control_controller_test.exs`, `launcher-remote.test.mjs`.
- **Acceptance.**
  - [ ] **[fails without]** Two POSTs of `pause` with one `request_id`: the pause function runs once; both responses are equal.
  - [ ] **[fails without]** Same id, different expression: HTTP 422 `request_id_reused`.
  - [ ] Second POST while the first still runs: HTTP 409 `request_in_progress`.
  - [ ] Contract version 1 requests behave as today.
- **Research MPG-204R** (complexity 2). Retention size limits, restart behaviour of in-flight entries (default: an
  in-flight entry found at boot becomes `outcome_unknown`).

### Split write scope into permission categories bound to a peer

- Plan id: MPG-205 · `lane:gateway-trust` · complexity 3 · depends on: MPG-204, MPG-205R
- **Outcome.** Every allowlist entry has one category: `read`, `message`, `executor`, `agents`, `tickets`,
  `config`, or `trust`. Client tokens may carry `peer` (a gateway id) and `categories`. A call needs its category in the token
  and in the peer's grant (MPG-206).
- **Next action.** Replace the scope value in each `allowlist.ex` entry with a category, keeping a function
  `scope_of(category)` that returns `:read` for `read` and `:write` otherwise.
- **Files.** `src/lib/aiur/control_call/allowlist.ex`; `src/lib/aiur/client_tokens.ex` (fields `peer`, `categories`);
  `src/lib/aiur/client_tokens_cli.ex` (`token create --peer <id> --categories a,b`); `control_controller.ex`;
  tests `src/test/aiur/control_call/allowlist_category_test.exs`, `src/test/aiur/client_tokens_test.exs`;
  docs `website/docs-app/reference/cli-operations.md` (token section).
- **Acceptance.**
  - [ ] **[fails without]** A token with `categories: [read, message]` can call `message` and is refused `pause` (403 `category_not_granted: agents`).
  - [ ] Existing tokens: `read` maps to `[read]`, `write` to every category except `trust`.
  - [ ] No allowlist entry has category `trust` reachable remotely (test enumerates).
  - [ ] Categories: `pause`/`resume`/`park`/`redispatch` → agents; `queue`, `--todo`, `take`, `release`, `lane`, `epic`, `feature`, `ticket assign` → tickets; `set` → config; `message`, `command request` → message; `executor-*` (wait, claim, answer, revoke, emit) → executor.
- **Research MPG-205R** (complexity 2). Classify all allowlist entries; list any that do not fit (default: the stricter category).

### Grant, revoke and inspect peer permissions on the receiving gateway

- Plan id: MPG-206 · `lane:gateway-trust` · complexity 3 · depends on: MPG-205, MPG-002, MPG-206R
- **Outcome.** `aiur gateway permissions [<peer>]`, `gateway grant <peer> <categories>`,
  `gateway revoke <peer> [<categories>]` and `gateway trust <peer> --full` manage a `peers:` section in
  `~/.aiur/machine`. They run only locally (refused over `--gateway`). Granting `read` takes effect at once; any
  wider grant or `trust --full` is stored under `pending` and raised as a human-required Decision. It takes effect
  only when answered from a signed-in dashboard session (Google or passkey); a client token cannot answer it.
- **Settled.** Q5, decided by Kevin: read-only by default; full mutual trust is one command per side, confirmed by a signed-in human.
- **Next action.** Add `src/lib/aiur/machine/settings/schema/peers.ex` and `src/lib/aiur/gateway/grants.ex`
  (`allowed?(peer_id, category)`), and call `allowed?` from `control_controller.ex` for tokens with a `peer`.
- **Files.** the two modules; `src/lib/aiur/gateway/cli.ex` (new); `packaging/npm/aiur-cli/libexec/aiur-gateway.sh`
  (new namespace file, sourced like `aiur-feature.sh`); `aiur-engine.sh` dispatch; tests
  `src/test/aiur/gateway/grants_test.exs`, `packaging/npm/aiur-cli/test/launcher-gateway.test.mjs`;
  docs new `website/docs-app/reference/cli-gateways.md` (add to sidebar in `website/docs-app/.vitepress/config.ts`).
- **Acceptance.**
  - [ ] **[fails without]** Peer granted `[read]` calls `pause`: 403. After `gateway grant <peer> agents`, still 403 (pending). After the Decision is answered through a dashboard session, the call succeeds.
  - [ ] Answering that Decision with a client token (any category) is refused.
  - [ ] `gateway trust <peer> --full`, once confirmed, grants `read, message, executor, agents, tickets, config` and never `trust`.
  - [ ] `aiur --gateway x gateway grant ...` exits 64 `grant changes are local to the receiving gateway`.
  - [ ] Every grant change and confirmation writes an audit line naming the actor kind.
- **Research MPG-206R** (complexity 2). The Decision kind for pending grants, how the dashboard session proves a
  human, grant expiry (default: none for MVP), how revocation also revokes the peer's tokens.

### Answer unauthenticated hello and list discoverable gateways

- Plan id: MPG-207 · `lane:gateway-trust` · complexity 2 · depends on: MPG-001, MPG-206, MPG-207R
- **Outcome.** `GET /api/v1/gateway/hello` returns `{gateway_id, gateway_label, build, tls_fingerprint_sha256,
  enrollment: "open"|"closed"}` and nothing else. `aiur gateway discover` lists tailnet peers (from
  `tailscale status --json` when the binary exists) and registry entries that answer hello, marked
  `discovered (not enrolled)` or `enrolled`.
- **Next action.** Add the route in `src/lib/aiur_web/routes/api.ex` and a controller
  `src/lib/aiur_web/controllers/gateway_hello_controller.ex`; add `discover` to `src/lib/aiur/gateway/cli.ex`.
- **Files.** above; `src/lib/aiur/gateway/discovery.ex` (new); tests
  `src/test/aiur_web/controllers/gateway_hello_controller_test.exs`, `src/test/aiur/gateway/discovery_test.exs`;
  config key `server.gateway_hello: true|false` (default true on tailnet-bound or loopback, false on public bind) in
  `src/lib/aiur/config/schema/server.ex`; docs `configuration-daemon.md`, `cli-gateways.md`.
- **Acceptance.**
  - [ ] **[fails without]** `GET /api/v1/gateway/hello` with no credential returns 200 and exactly the five keys.
  - [ ] With `server.gateway_hello: false` it returns 404.
  - [ ] `gateway discover` with no `tailscale` binary lists registry entries only and says Tailscale was not found.
  - [ ] Discovery never writes the registry or any grant (test asserts files unchanged).
- **Research MPG-207R** (complexity 2). Tailscale peer filtering by tag or capability; whether to use LocalAPI
  `WhoIs` for identity (see `docs/research/multi-gateway/gateway-enrollment-and-permissions.md`).

### Enrol a peer with a one-time invite

- Plan id: MPG-208 · `lane:gateway-trust` · complexity 3 · depends on: MPG-206, MPG-207, MPG-201, MPG-208R
- **Outcome.** On B, `aiur gateway invite --grant read,message [--ttl 10m]` prints one code holding B's url,
  gateway id, TLS fingerprint and a single-use secret. On A, `aiur gateway join <code> --name <n>` checks B's hello
  against the code, sends A's gateway id and label, receives a peer-bound token, and writes the registry entry with
  the pin. B's grants for A are those in the invite.
- **Next action.** Add `POST /api/v1/gateway/enroll` (`src/lib/aiur_web/controllers/gateway_enroll_controller.ex`)
  and `src/lib/aiur/gateway/invites.ex` (hashed secrets, expiry, single use).
- **Files.** above; `src/lib/aiur/gateway/cli.ex` (`invite`, `join`, `register`, `remove`, `rotate`);
  `engine/remote.sh` (write registry entry, token file mode 0600); tests
  `src/test/aiur/gateway/invites_test.exs`, `gateway_enroll_controller_test.exs`, `launcher-gateway.test.mjs`;
  docs `cli-gateways.md`.
- **Acceptance.**
  - [ ] **[fails without]** Join with a valid code creates a registry entry with `gateway_id`, a 0600 token file, and on B a `peers:` row with the invited grants.
  - [ ] Reusing a code, using it after its TTL, or a hello fingerprint that differs from the code: refused, nothing written on either side.
  - [ ] `invite` is local only; an invite wider than `read` creates pending grants (same rule as MPG-206).
- **Settled.** Q5, decided by Kevin: read-only by default; full mutual trust is one command per side, confirmed by a signed-in human.
  - [ ] `gateway register <name> --url <u> --token-file <f>` (manual, no invite) works with no Tailscale.
  - [ ] `gateway rotate <peer>` issues a new token, keeps the old one valid for 10 minutes, then revokes it.
- **Research MPG-208R** (complexity 2). Code encoding (default: `aiur-invite:` + base64url JSON), TLS fingerprint
  source when a tunnel terminates TLS (default: pin disabled, token only, warn).

### Show gateway status from the CLI

- Plan id: MPG-209 · `lane:gateway-cli` · complexity 2 · depends on: MPG-202, MPG-207, MPG-209R
- **Outcome.** `aiur gateway list` shows every registry entry with `registered`, connectivity
  (`online|offline|unknown|error`), last seen age, gateway id, projects, running agents, owned tickets, Executor
  presence and effective grants in both directions where known. `gateway status <g>` shows one in detail.
  Offline gateways show last-known values with their age, never zero.
- **Next action.** Add `list` and `status` to `src/lib/aiur/gateway/cli.ex`, calling hello and `status --json` per
  entry in parallel through `engine/remote_all.sh`, and cache the last good answer in `~/.aiur/remote-state/<name>.json`.
- **Files.** above; tests `src/test/aiur/gateway/status_test.exs`, `launcher-gateway.test.mjs`; docs `cli-gateways.md`.
- **Acceptance.**
  - [ ] **[fails without]** One reachable and one unreachable stub: the unreachable row shows `offline` and `agents: 3 (12m ago)` from the cache.
  - [ ] An entry never reached shows `unknown`, and totals print `12 + unknown`.
  - [ ] `--json` emits `{gateway, connectivity, workload, last_seen_at, age_ms, freshness}` per row.
- **Research MPG-209R** (complexity 1). Workload states (`idle|active|saturated|paused`) derived from status fields.

### Prove registered gateways and remote control between PC and Nook

- Plan id: MPG-210 · `lane:acceptance` · complexity 3 · depends on: MPG-202, -203, -204, -206, -208, -209, MPG-210R
- **Outcome.** Live evidence for acceptance tests G1-G9 in the plan.
- **Acceptance.**
  - [ ] Each of G1-G9 has a recorded command, its output (secrets and addresses redacted) and pass/fail.
  - [ ] With a `message`-only token, POST a grant-changing expression straight to `/api/v1/control` (bypassing the CLI gate): 403 from the receiver, and the audit log shows the denial.
- **Research MPG-210R** (complexity 1). Runbook with exact commands and expected outputs.
