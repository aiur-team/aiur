---
pageClass: cli-reference
---
# CLI gateway permissions and discovery

Each peer's `allows` block in `~/.aiur/remote-instances.yaml` sets what it may do here, and a peer with no block gets `read` only.

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur gateway permissions [<peer>] [--json]` | Lists every peer with its categories, credential count and any open grant Decision. With a peer, adds its last five audit lines. `--json` carries `observed_at`, `age_ms` and `freshness` (the registry file's modified time). `<peer>` is a registry name, label or gateway id. | `aiur gateway permissions nook` |
| `aiur gateway grant <peer> <categories>` | `read` is written at once. Any other category raises a human-required Decision and is written only after you confirm it on this gateway's dashboard. The peer needs a `gateway_id` in the registry. | `aiur gateway grant nook read,agents` |
| `aiur gateway revoke <peer> [<categories>]` | With categories, removes just those from the peer; tokens stay but are refused for them. With none, sets `categories: []` and deletes every client token bound to the peer and every name in `allows.credentials`. An unknown peer exits 66. | `aiur gateway revoke nook agents` |
| `aiur gateway trust <peer> --full` | Same as granting `read,message,executor,agents,tickets,config`, with one Decision. `--full` never includes `trust`. Mutual trust is one command on each gateway. | `aiur gateway trust nook --full` |
| `aiur gateway discover [--port N] [--json]` | Read-only. Probes each registry entry's `url` and every online `tag:gateway` tailnet peer (from `tailscale status --json`, on `--port`, default this daemon's port) with the anonymous `GET /api/v1/gateway/hello`, sending no credential. Rows: `enrolled`, `discovered (not enrolled)`, `identity mismatch` (hello id differs from the pinned `gateway_id`), `answered, unrecognised` (not exactly the five hello keys) and `unreachable` (registry entries only; silent tailnet peers are omitted). Without the `tailscale` binary it lists registry entries and says `Tailscale not found; showing registered gateways only`. `--json` rows carry `observed_at`, `age_ms` and `freshness`. | `aiur gateway discover` |
| `aiur gateway list [--json]` | Read-only. One row per registry entry: `registered`, connectivity, workload, last seen, gateway id, agents and grants. Each entry is read in parallel (5 s each, `AIUR_GATEWAY_TIMEOUT_SECONDS`) with `agents --json` and the anonymous hello. The last line totals agents: `15 (3 cached)` when some counts come from an offline gateway's cache, `12 + unknown` when an entry has never answered. `--json` emits `{gateways, totals}`; `totals` is `{agents, unknown}` (the sum of known counts, cached included, and the number of rows with no count). Each row carries `gateway`, `registered`, `connectivity`, `reason`, `workload`, `last_workload`, `last_seen_at`, `age_ms`, `freshness`, `gateway_id`, `agents`, `projects`, `owned_tickets`, `executor`, `grants_to_peer` and `grants_from_peer`. `agents`, `last_seen_at` and `age_ms` are null when never reached; `projects`, `owned_tickets`, `executor` and `grants_from_peer` are null until gateways report them. | `aiur gateway list` |
| `aiur gateway status <gateway> [--json]` | The same fields for one registry entry, one per line. Exits 66 for a name not in the registry. | `aiur gateway status nook` |
| `aiur gateway reload` | Re-reads `projects:` in `~/.aiur/machine`: starts added projects and any that failed, stops removed ones, and leaves every other project tree running. Prints `started:`, `stopped:`, `unchanged:` and `failed:` lines. Local to the gateway's host. | `aiur gateway reload` |

Connectivity is one of:

- `online`: hello and `agents --json` both answered.
- `offline`: no answer.
- `unknown`: never reached.
- `error`: answered, but `reason` says why.

`reason` is null unless connectivity is `error`:

- `refused`: the authenticated call was refused.
- `invalid hello`: the hello was not recognised.
- `pin mismatch`: the gateway id differs from the pinned one.
- `hello disabled`: hello returned 404 (`server.gateway_hello: false`, the default on a non-loopback, non-tailnet bind), so the id was not checked.

Each online answer is cached in `~/.aiur/remote-state/<name>.json`. An offline gateway shows that cache with its age (`agents: 3 (12m ago)`, `freshness: stale`) and workload `unknown`, with the cached value in `last_workload`; it is never `idle` or `0`.

Workload is `active` (running agents), `idle`, or `unknown` unless the gateway is `online`. `saturated`, `paused`, projects, owned tickets and Executor presence are `unknown` until gateways report them.

The hello answer is `{gateway_id, gateway_label, build, tls_fingerprint_sha256, enrollment}` and nothing else; [`server.gateway_hello`](./configuration-daemon) turns it off.

The permission commands edit the local file only. Over `--gateway` or `--instance` they are refused: `aiur --gateway nook gateway grant …` exits 64 with `grant changes are local to the receiving gateway`.

## Enrolling a peer with an invite

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur gateway invite [--grant <categories>] [--ttl <n>[smhd]] [--url <u>] [--tls-pin <hex>]` | Run on the gateway being joined (B). Prints one `aiur-invite:` code holding B's URL, gateway id, TLS pin and a single-use secret. `--ttl` defaults to 10 minutes (maximum 24 hours); `--url` defaults to `server.public_url`; the pin defaults to `server.tls_pin_sha256`, and with none the command warns `no TLS pin`. `read` is always included; `trust` is rejected. The grants stay in B's invite record, not in the code. | `aiur gateway invite --grant read,message --ttl 10m` |
| `aiur gateway join <code> --name <n>` | Run on the joining gateway (A); needs no running daemon. Checks B's hello against the code and sends the secret only if the gateway id matches and enrolment is `open`; with a pin in the code, both calls are pinned. Then writes the registry entry for B (`url`, `gateway_id`, `label`, `tls_pin_sha256` when pinned) and a mode 0600 token file at `~/.aiur/peers/<n>.token`. A used, expired, mismatched or refused code writes nothing. | `aiur gateway join aiur-invite:… --name nook` |
| `aiur gateway register <name> --url <u> --token-file <f> [--tls-pin <hex>]` | Adds an entry by hand, with no invite and no Tailscale. The token file must exist (mode 0600 is checked when it is used). | `aiur gateway register pc --url https://pc.example.com --token-file ~/pc.token` |
| `aiur gateway remove <peer>` | Deletes the registry entry and revokes every client token bound to the peer. An unknown peer exits 66. | `aiur gateway remove nook` |
| `aiur gateway rotate <peer>` | Run on the side that issued the token. Mints a new token and prints it once; the old one works for 10 minutes, then is revoked and dropped from `allows.credentials`. Move the new token with `gateway register`. | `aiur gateway rotate nook` |

On B, a valid enrolment burns the invite, creates a token bound to A's gateway id and adds A to the registry with `read`.

Any invited write category becomes a Decision you must confirm signed in (see below), and `join` prints `pending on <n>: …`. Mutual trust needs an invite in each direction.

The enrol route allows 5 attempts a minute per remote IP, then answers 429 even for a correct secret. Behind a proxy or tunnel not listed in `server.trusted_proxies`, every caller shares one address, so five bad attempts pause all enrolment for a minute.

Unknown id and wrong secret return the same 401. A peer's token never exceeds its registry entry: an invited write category works only after you confirm it.

With no pin, `join` trusts whatever certificate answers at the URL; the secret is single-use and the new peer starts read-only. If B enrolled A but the answer was lost, run `aiur gateway remove <peer>` on B and issue a new invite.

All five are local: over `--gateway` or `--instance` they exit 64 with `<command> is local to the gateway it changes`.

Hello reports `enrollment: open` while an unused, unexpired invite exists, and `tls_fingerprint_sha256` is `server.tls_pin_sha256` or `null`. Audit events add `enrolled`, `enroll_refused`, `invite_created`, `peer_removed` and `token_rotated`.

## Categories

`read`, `message`, `executor`, `agents`, `tickets` and `config`; `trust` is rejected anywhere in the file.

A call needs its category in **both** the token and the peer's `allows.categories`, or the receiver answers 403 `category_not_granted: <category>`.

Grant changes arriving on `/api/v1/control` get 403 `grants_are_local` and are audited.

## Confirming a write grant

`gateway grant` prints the open Decision's id. Answer it on this gateway's dashboard signed in with **Google or a passkey** within 15 minutes of sign-in.

Basic Auth, client tokens, the Executor and supervisors cannot confirm, and a Decision from another gateway never matches. Without Google or passkeys, edit the file by hand.

## Editing the file by hand

A hand edit is equally valid and applies on the next request, with no restart:

```yaml
version: 1
instances:
  nook:
    gateway_id: <26 base32 characters>
    allows:
      categories: [read, agents]
      credentials: [nook-token]   # optional; when set, only these client token names are accepted
```

A file with an inline `token`, `secret` or `password` key, an unknown category or `trust` is rejected with the key named, and the last good registry stays in force (`gateway permissions` shows the error). Before any good registry has loaded, peer-bound calls get 403 `grants_unavailable`. Writes by the commands drop YAML comments.

## Audit

Every change appends a line to `control-audit.ndjson` under the daemon log root, naming the actor: `cli_local`, `dashboard_google`, `dashboard_passkey` or `unknown_local_editor` (a hand edit).

Events: `grant_requested`, `grant_confirmed`, `grant_denied`, `grant_written`, `grant_revoked`, `token_revoked`, `grants_are_local_refused`, `category_not_granted_refused`, `file_edit_detected`.
