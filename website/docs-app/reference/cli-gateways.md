---
pageClass: cli-reference
---
# CLI gateway permissions

A gateway decides what each peer gateway may do **on itself**. The grants live in the `allows` block of that peer's entry in `~/.aiur/remote-instances.yaml`, and the receiving gateway enforces them. The commands below read and edit that file on the gateway where you run them. They are refused over `--gateway` or `--instance`: `aiur --gateway nook gateway grant …` exits 64 with `grant changes are local to the receiving gateway`.

A peer starts read-only. A peer entry with no `allows` block permits `read` only.

| Syntax | Default or important interaction | Runnable example |
| --- | --- | --- |
| `aiur gateway permissions [<peer>] [--json]` | Lists every peer with its categories, credential count and any open grant Decision. With a peer, adds its last five audit lines. `--json` carries `observed_at`, `age_ms` and `freshness` (the registry file's modified time). `<peer>` is a registry name, label or gateway id. | `aiur gateway permissions nook` |
| `aiur gateway grant <peer> <categories>` | `read` is written at once. Any other category raises a human-required Decision and is written only after you confirm it on this gateway's dashboard. The peer needs a `gateway_id` in the registry. | `aiur gateway grant nook read,agents` |
| `aiur gateway revoke <peer> [<categories>]` | With categories, removes just those from the peer; tokens stay but are refused for them. With none, sets `categories: []` and deletes every client token bound to the peer and every name in `allows.credentials`. An unknown peer exits 66. | `aiur gateway revoke nook agents` |
| `aiur gateway trust <peer> --full` | Same as granting `read,message,executor,agents,tickets,config`, with one Decision. `--full` never includes `trust`. Mutual trust is one command on each gateway. | `aiur gateway trust nook --full` |

## Categories

`read`, `message`, `executor`, `agents`, `tickets` and `config`. `trust` is not a category and is rejected anywhere in the file. A call from a peer's token is allowed only when **both** the token's categories and the peer's `allows.categories` contain the call's category; otherwise the receiver answers 403 `category_not_granted: <category>`. Grant-changing calls arriving on `/api/v1/control` are refused with 403 `grants_are_local` and audited, whatever the token holds.

## Confirming a write grant

`gateway grant` prints the open Decision's id. Open this gateway's dashboard signed in with **Google or a passkey** and answer the Decision. A sign-in older than 15 minutes, a Basic Auth session, a client token, the Executor and a supervisor cannot confirm it, and a Decision raised on another gateway never matches this one. If neither Google nor passkeys are configured, edit the file by hand.

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

Every change appends a line to `control-audit.ndjson` under the daemon log root, naming the actor kind: `cli_local`, `dashboard_google`, `dashboard_passkey` or `unknown_local_editor` (a hand edit, event `file_edit_detected`). Events: `grant_requested`, `grant_confirmed`, `grant_denied`, `grant_written`, `grant_revoked`, `token_revoked`, `grants_are_local_refused`, `category_not_granted_refused`.
