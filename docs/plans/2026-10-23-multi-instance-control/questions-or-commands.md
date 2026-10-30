# Questions and decisions for the operator

Every item has a recommended default. None blocks the plan; the Executor proceeds on the default unless the operator answers otherwise. Answering one changes only the tickets named.

## Decisions carried in from the operator conversation (recorded, not re-asked)

| ID | Decision | Recommended default | Affects |
|---|---|---|---|
| D1 | Agents inside the Railway service, or separate workers | Separate workers (#5953); #5946 trusted-container mode remains the interim opt-in | none in this pack |
| D2 | Subscription or API keys for cloud agents | Subscription for the operator's own instances (#5943 `operator` kind) | none in this pack |
| D3 | Lease store: GitHub compare-and-swap or Postgres | Postgres (Railway-managed; home instances reach it over TLS). The store's reachability from home machines is a #5947 acceptance item | MIC-008 via #5947 |
| D4 | Railway plan size | Start one service on the smallest paid plan that allows a volume, `max-agents` 4, and resize from #5952's measured sizing table rather than a guess | MIC-010 step 7 |

## Decisions this plan introduces

| ID | Question | Recommended default | Why | Affects |
|---|---|---|---|---|
| D5 | Wire format for remote calls | Forward the engine's call expression under a literal-only allowlist (KTD1-KTD2) | Zero per-command code; output parity by construction | MIC-001-003 |
| D6 | Registry file name | `~/.aiur/remote-instances.yaml` | `~/.aiur/instances/` already holds per-instance dashboard secrets | MIC-003 |
| D7 | `--instance all` for write commands | Refused, except `executor-wait` (MIC-006); the server enforces it with `max_scope: read` on every other fan-out | A fleet-wide pause by accident is costly; reads are safe; the fleet Executor needs one merged wait | MIC-004, MIC-006 |
| D8 | Audit record content | Function and expression hash, not argument text | `message` text can hold anything; the hash still ties a record to a request | MIC-002 |
| D9 | Where ownership rules live | Per-instance config `instance.owns`, published in #5947 heartbeats | The operator asked for a config setting; no new shared document | MIC-008 |
| D10 | Retire per-machine Executors | Yes, once MIC-006 merges; the fleet Executor runs on the PC | One Executor is the goal of the request | MIC-006, aiur-run skill |
| D11 | Settable keys in v1 | KTD9 list (caps, routing, backend priority, queue sets, `instance.ignore.tickets`; `instance.owns` from MIC-008) | The operator's examples; `instance.role` needs a restart, so it stays YAML-only | MIC-007, MIC-008 |
| D12 | #5950's `aiur status --all-instances` flag | Drop the flag; show the lease-store roster as a section of plain `aiur status`, and use `aiur --instance all status` for live per-instance detail | Avoid two flags that both mean "all instances" | amendment A2 |
| D13 | Remote `stop`/`restart` | Not supported; use the host's service manager | They manage host processes, not daemon state | MIC-003 |

## Commands the operator may want to run later (not run by this spike)

- Promotion of this pack (Executor-owned, after approval): see README "Executor handoff".
- Token setup per instance after #5945 merges: `aiur token create pc-read --scope read`, `aiur token create pc-write --scope write`.
