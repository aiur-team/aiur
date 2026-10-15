# Build history commands

## Features

Feature collections own tickets; also-affects links do not add ownership, and operations use the local registry without checking issue numbers against GitHub.

Label projection runs separately; `show` reports its state, including `unknown` when unavailable.

| Syntax | Behavior | Runnable example |
| --- | --- | --- |
| `aiur feature create <slug> --label <text> [--hue <0-359>] [--epic <key>=<label>]… [--as <who>] [--json]` | Creates a collection; matching requests are unchanged. Default epic: `f-<slug>`. | `aiur feature create intake --label "Intake" --hue 145 --json` |
| `aiur feature add <slug> <ids…> [--epic <key>] [--move] [--source backfill-agent] [--as <who>] [--json]` | Joins up to 200 issue numbers below 2^31, optional `#`, duplicates collapsed. Conflicting ownership refuses the batch; `--move` transfers it. | `aiur feature add intake 412 413 --move --json` |
| `aiur feature remove <slug> <ids…> [--as <who>] [--json]` | Removes owning memberships; absent memberships are unchanged. | `aiur feature remove intake 412 --json` |
| `aiur feature also <slug> <ids…> [--remove] [--as <who>] [--json]` | Adds or removes also-affects links. Owners cannot also affect the same feature. | `aiur feature also intake 420 --json` |
| `aiur feature baseline <slug> [--replace] [--as <who>] [--json]` | Records original scope. Existing baselines require `--replace`; replacement reports the previous time and count. | `aiur feature baseline intake --json` |
| `aiur feature edit <slug> [--label <text>] [--hue <0-359>] [--end now or <ISO-8601>] [--add-epic <key>=<label>]… [--as <who>] [--json]` | Renames, ends, or adds epics; requires a change. Each edit and epic addition is a separate settled write. | `aiur feature edit intake --label "Ready" --json` |
| `aiur feature show [<slug>] [--json]` | Lists collections or shows members, provenance, labels and baseline age; no progress figures. | `aiur feature show intake --json` |

All verbs accept `--json` (schema version 1); writes accept `--as <who>`, default `$USER`, with 1–64 letters, digits, dots, underscores or hyphens. Actor/source are `cli:<who>`.

Only `add --source backfill-agent` changes source, leaving actor intact and membership unconfirmed. Confirmed membership remains confirmed on a repeated backfill.

Agents use `aiur_feature` with daemon-bound `agent:<issue number>` identity; they cannot edit or set baselines. Tool `backfill: true` is restricted to add.

Exit codes: 0 success/unchanged, 1 refusal or unavailable registry, 64 invalid arguments, 124 RPC timeout (outcome unknown). After timeout, re-run and inspect outcomes; a repeated baseline without `--replace` refuses if the first attempt landed.

JSON preserves unavailable label totals and absent baselines as `null`; missing per-ticket label states are `unknown`.

Example: `aiur feature create intake --label "Intake"`, then `aiur feature add intake 412 413` and `aiur feature show intake --json`.

## Epics

Overrides are local: these commands never write GitHub labels or report effective epics, and agents use `aiur_set_epic` with daemon-bound identity.

| Syntax | Behavior | Runnable example |
| --- | --- | --- |
| `aiur epic set <epic> <ids…> [--source cli\|backfill-agent] [--as <who>] [--json]` | Atomically sets up to 200 IDs (optional `#`; duplicates count once). Only configured general epics; feature epics and `unsorted` are refused. | `aiur epic set runtime 142 143 --source cli --json` |
| `aiur epic clear <ids…> [--as <who>] [--json]` | Removes overrides; absent entries are unchanged. | `aiur epic clear 142 --json` |
| `aiur epic show [<ids…>] [--json]` | Shows stored epic, actor, source, confirmation and time. Removed keys are ignored; unreadable config gives `epic_known: null`. | `aiur epic show 142 --json` |
| `aiur epic list [--json]` | Lists configured keys and labels in order. Config errors refuse writes and list without defaults. | `aiur epic list --json` |

Identity: the actor defaults to `cli:$USER`; `--as` accepts 1–64 letters, digits, dots, underscores or hyphens. Source defaults to actor; `backfill-agent` is unconfirmed. CLI cannot claim agent identity. Repeating the same epic, source and confirmation is unchanged; changed results and the journal retain the prior assignment.

Recovery: unsafe journals remain unavailable. Move corrupt `epic-overrides.json` aside in the instance’s `epic-overrides` directory, then restart; GitHub cannot rebuild overrides.

After a first-write sync failure after rename, reads and writes remain unavailable until restart. Exit codes are 0 success, 1 refusal/unavailability, 64 usage, and 124 RPC timeout with unknown outcome. Retrying the same set is safe.
