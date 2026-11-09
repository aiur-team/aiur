# Multi-project gateways: state schemas S2-S6

Part of [the plan](../2026-11-06-multi-project-gateways.md), which holds S1 (the ownership record). Field names here are
the contract the tickets implement.

**S2 Gateway registry config: one peer entry** (`~/.aiur/remote-instances.yaml`, version 1, mode 0600, outside
Git; new keys optional). Kevin decided that a gateway's write grants live here: this file is the source of truth the
gateway enforces for incoming calls. CLI and dashboard grant actions edit it; a hand edit is equally valid. No remote
command can write it. Secrets never appear in it, only references to them.

```yaml
version: 1
instances:                                   # one entry per peer gateway; the key is a local name
  nook:
    gateway_id: <26 base32>                  # peer identity, pinned; a response with another id is refused
    label: Nook
    url: https://<endpoint>                  # where this gateway calls the peer; omit for an inbound-only peer
    token_file: ~/.aiur/peers/nook.token     # credential reference for outbound calls (or token_env: AIUR_TOKEN_NOOK)
    tls_pin_sha256: <hex>                    # optional, for self-signed endpoints
    allows:                                  # what THIS peer may do on THIS gateway; enforced here
      categories: [read]                     # default when absent: [read]
      credentials: [<client token id>]       # ids of the peer's inbound tokens; hashes stay in client-tokens.json
```

Directional: on Nook, the entry for PC says what PC may do on Nook; on PC, the entry for Nook says what Nook may do
on PC. Categories: `read`, `message`, `executor`, `agents`, `tickets`, `config`; `trust` is rejected. Validation
rejects inline secret keys (`token`, `secret`, `password`) and unknown categories. Today's launcher and Stream Deck
parsers ignore the `allows` block.

**S3 Machine config additions** (`~/.aiur/machine`, mode 0600, never in Git):

```yaml
projects:
  - repo: owner/name
    config: /absolute/path/to/checkout/.aiur/config
    max_agents: 8          # optional per-project ceiling
    priority: 1            # local fallback when no shared intent is known
capacity: {max_agents: 12}
coordination: {database_url_env: AIUR_LEASE_DATABASE_URL, offline_after_seconds: 180}
```

**S4 Shared intent** (coordination Postgres; mirrored locally as `intent/changes.ndjson`, `intent/registers.json`, `intent/hlc.json`,
`intent/outbox.ndjson` under the gateway state root):

```text
aiur_intent_changes(seq bigserial, change_id uuid primary key, hlc_wall_ms bigint, hlc_counter int,
  origin_gateway text, slot text,            -- human | executor | default
  author_id text, entity_kind text, entity_key text, field text, value_json jsonb,
  supersedes uuid null, force boolean, reason text, received_at timestamptz)
aiur_intent_registers(entity_kind, entity_key, field, winning_change_id, value_json,
  primary key (entity_kind, entity_key, field))
```

Entities: `project`, `feature`, `ticket` (field `order_key`, a fractional index string), `gateway` and `fleet`
(field `pause`). Scheduler choices are never written here.

**S5 Audit line** (`control-audit.ndjson`, existing fields plus): `request_id`, `origin_gateway`, `actor`,
`category`, `peer`.

**S6 Gateway summary** (`GET /api/v1/gateway/summary`): `{gateway_id, gateway_label, observed_at, age_ms,
connectivity, workload, capacity: {max, running}, projects: [{repo, observed_at, age_ms, focus_features, running,
ready, owned_tickets, paused, agents, next_queue, pending_decisions}], executor_present}`.

`agents`, `next_queue` and `pending_decisions` are each `{state, value, observed_at, age_ms}`. `state` is `known` or
`unknown`; an unreadable store gives `unknown` with `value: null`, never `0`. `agents` is the project's current agent
count, `next_queue.value` is `{number}` (the first startable queue item, `number: null` when nothing is ready), and
`pending_decisions` is the count of Commands waiting on the operator. The queue serves only the configured tracker
repo, so any other project reports `next_queue` as `unknown`.

