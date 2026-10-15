# Build history commands

## Features

Feature collections own tickets; also-affects links do not add ownership, and operations use the local registry without checking issue numbers against GitHub.

Label projection runs separately; `show` reports its state, including `unknown` when unavailable.

| Command | Behaviour |
| --- | --- |
| `aiur feature create <slug> --label <text> [--hue <0-359>] [--epic <key>=<label>]…` | Create a collection; matching requests are unchanged. Default epic: `f-<slug>`. |
| `aiur feature add <slug> <ids…> [--epic <key>] [--move] [--source backfill-agent]` | Join up to 200 issue numbers below 2^31, optional `#`, duplicates collapsed. Conflicting ownership refuses the whole batch; `--move` transfers it. |
| `aiur feature remove <slug> <ids…>` | Remove owning memberships; absent memberships are unchanged. |
| `aiur feature also <slug> <ids…> [--remove]` | Add or remove also-affects links. Owners cannot also affect the same feature. |
| `aiur feature baseline <slug> [--replace]` | Record original scope. Existing baselines require `--replace`; replacement reports the previous time and count. |
| `aiur feature edit <slug> [--label <text>] [--hue <0-359>] [--end now\|<ISO-8601>] [--add-epic <key>=<label>]…` | Rename, end, or add epics; requires a change. Each edit and epic addition is a separate settled write. |
| `aiur feature show [<slug>]` | List collections or show members, provenance, labels and baseline age; no progress figures. |

All verbs accept `--json` (schema version 1); writes accept `--as <who>`, default `$USER`, with 1–64 letters, digits, dots, underscores or hyphens. Actor/source are `cli:<who>`.

Only `add --source backfill-agent` changes source, leaving actor intact and membership unconfirmed. Confirmed membership remains confirmed on a repeated backfill.

Agents use `aiur_feature` with daemon-bound `agent:<issue number>` identity; they cannot edit or set baselines. Tool `backfill: true` is restricted to add.

Exit codes: 0 success/unchanged, 1 refusal or unavailable registry, 64 invalid arguments, 124 RPC timeout (outcome unknown). After timeout, re-run and inspect outcomes; a repeated baseline without `--replace` refuses if the first attempt landed.

JSON preserves unavailable label totals and absent baselines as `null`; missing per-ticket label states are `unknown`.

Example: `aiur feature create intake --label "Intake"`, then `aiur feature add intake 412 413` and `aiur feature show intake --json`.

## Epics

Overrides are local: these commands never write GitHub labels or report effective epics, and agents use `aiur_set_epic` with daemon-bound identity.

| Command | Behavior |
| --- | --- |
| `aiur epic set <epic> <ids…> [--source cli\|backfill-agent] [--as <who>] [--json]` | Atomic, up to 200 IDs (optional `#`; duplicates count once). Only configured general epics; feature epics and `unsorted` are refused. |
| `aiur epic clear <ids…> [--as <who>] [--json]` | Remove overrides; absent entries are unchanged. |
| `aiur epic show [<ids…>] [--json]` | Stored epic, actor, source, confirmation, time. Removed keys are ignored; unreadable config gives `epic_known: null`. |
| `aiur epic list [--json]` | Configured keys and labels in order. Config errors refuse writes and list without defaults. |
| Identity | Actor defaults to `cli:$USER`; `--as` accepts 1–64 letters, digits, dots, underscores or hyphens. Source defaults to actor; `backfill-agent` is unconfirmed. CLI cannot claim agent identity. |
| Repeats | Same epic/source/confirmation is unchanged. Changed results and journal retain the previous assignment. |
| Recovery | Unsafe journals are unavailable. Move corrupt `epic-overrides.json` aside in the instance’s `epic-overrides` directory, then restart; GitHub cannot rebuild overrides. First-write sync failure after rename leaves reads/writes unavailable until restart. |
| Exit codes | 0 success; 1 refusal/unavailability; 64 usage; 124 RPC timeout with unknown outcome. Retrying an identical set is safe. |
