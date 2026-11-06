# Multi-project gateways: state schemas S2-S6

Part of [the plan](../2026-11-06-multi-project-gateways.md), which holds S1 (the ownership record). Field names here are
the contract the tickets implement.

**S2 Registry entry** (`~/.aiur/remote-instances.yaml`, version 1; new keys optional):

```yaml
instances:
  nook:
    url: https://<endpoint>
    token_file: ~/.aiur/peers/nook.token      # mode 0600; or token_env: AIUR_TOKEN_NOOK
    gateway_id: <26 base32>                   # pinned; a mismatch refuses the call
    label: Nook
    tls_pin_sha256: <hex>                     # only for self-signed endpoints
```

**S3 Machine config additions** (`~/.aiur/machine`, mode 0600, never in Git):

```yaml
projects:
  - repo: owner/name
    config: /absolute/path/to/checkout/.aiur/config
    max_agents: 8          # optional per-project ceiling
    priority: 1            # local fallback when no shared intent is known
capacity: {max_agents: 12}
coordination: {database_url_env: AIUR_LEASE_DATABASE_URL, offline_after_seconds: 180}
peers:                     # receiver-side grants (MPG-206)
  <peer gateway_id>: {label: PC, grants: [read, message], pending: [agents], token_ids: [<id>], added_at: <iso>}
```

**S4 Shared intent** (coordination Postgres; mirrored locally as `intent/changes.ndjson`, `intent/registers.json`,
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
ready, owned_tickets, paused, pending_decisions}], executor_present}`.

