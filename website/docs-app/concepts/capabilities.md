# Capabilities

An authenticated `GET /api/v1/capabilities` returns one read-only JSON report
with `contract: "aiur.capabilities"` and `contract_version: 1`. It uses the same
dashboard Basic auth boundary as `/api/v1/state` and sends `Cache-Control: no-store`.

It answers while orchestration is unavailable; it does not call the orchestrator.
With `--no-dashboard` there is no HTTP listener.

The report describes remote API capabilities. Local CLI operations keep their
own gates. A report is advisory: write endpoints still enforce authorization
and availability when a request arrives.

## Reading the report

Each capability has a `state`: `available`, `degraded`, `unavailable`, or `unknown`.
A non-available entry includes a `reason`; dependencies are listed in `depends_on`.
An omitted capability is unknown, never an empty result or zero.

Ignore unfamiliar
IDs and treat unfamiliar reasons as unknown. A missing ID introduced in a newer
contract version means the server needs an update.

`machine`, `instance`, `repository`, and `executor` identify the responding
instance. A null section means unknown. `instance.run_shape.http_listener` and
`dashboard_pages` distinguish API access from browser pages; `dashboard` is a
deprecated alias of `http_listener`.

`min_client_versions` maps client kinds to
minimum versions; an empty map imposes no minimum. Clients below a listed minimum
must block writes and request an update.

Cache by `(instance_id, boot_id, revision)`. `boot_id` changes on daemon restart;
`revision` increases within that boot when capabilities change and is not persisted.
Refetch on reconnect, a new boot, `system.capabilities.changed`, and before a write.

`observed_at` records computation time. `age_ms` is computed at read time using the
daemon's monotonic clock. `freshness` is `current` through 6,000 ms, then `stale`.

A missing registry table produces a synchronous report with revision zero and
explicitly stale freshness. Show the age when displaying freshness.
An unreachable instance, a stale report, and an unavailable capability are
separate conditions.

## Version 1 IDs

Registered IDs describe supported surfaces, including absent components; an ID's
presence does not promise that its feature is installed or enabled.

| ID | Surface |
| --- | --- |
| `identity` | Machine and instance identity |
| `api.http` | Instance HTTP API |
| `orchestration` | Ticket workflow orchestration |
| `instance.status` | Instance status |
| `agents.run` | Running ticket agents |
| `agents.message` | Sending messages to agents |
| `commands.read` | Reading Commands |
| `commands.answer` | Answering Commands |
| `commands.supervisor_api` | Supervisor Decision API |
| `build_orders` | Build Orders |
| `build_orders.progress` | Build Order progress |
| `build_queue` | Queue promotion |
| `build_queue.build_order_source` | Build Order dependency source for the queue |
| `conversations.read` | Conversation history |
| `conversations.anchors` | Conversation anchors |
| `executor.wakes` | Executor wake inbox |
| `executor.conversation` | Managed Executor conversation |
| `executor.background_agents` | Executor background agent observations |
| `harness.<id>.native_question` | Harness questions; `mode` is `in_band_hold`, `defer_resume`, or `none` |
| `events.export` | External event export; may include `v` and `retention` |
| `listener_modes` | Listener routing modes; unavailable modes retain legacy sends |
| `voice.stt` | Speech recognition |
| `voice.tts` | Speech synthesis |
| `voice.conversation` | Voice conversation |
| `streamdeck` | Stream Deck integration |
| `webhook_ingress` | GitHub webhook ingress |
| `remote_control` | Harness Remote Control |
| `pairing` | Device pairing |
| `push` | Push notifications |
| `runtime.crypto` | Required runtime cryptographic primitives |
| `tracker.github` | GitHub tracker |
| `tracker.linear` | Linear tracker |
| `accounting.meters` | Provider usage meters |
| `merge_policy` | Configured merge policy; `mode` is `ci=<mode> local_tests=<mode>` ([configuration](/reference/configuration#merge-policy)) |

Per-capability `version` defaults to 1. Registered `route` attributes tell clients
where to open a feature's dashboard page; do not hard-code those destinations.

## Reasons

| Reason | Meaning |
| --- | --- |
| `not_installed` | Component absent or not started in this run shape |
| `not_configured` | Required key or configuration missing |
| `disabled` | Operator disabled the feature |
| `not_running` | Expected process is down |
| `unsupported_tracker` | Tracker does not support the feature |
| `executor_absent` | No Executor present |
| `executor_not_managed` | Executor harness has no managed session |
| `snapshot_stale` | Snapshot exceeds its freshness budget |
| `snapshot_unpublished` | Snapshot has not been published |
| `instance_key_missing` | Launcher instance key missing |
| `instance_key_invalid` | Launcher instance key invalid |
| `identity_unreadable` | Machine identity cannot be safely loaded |
| `journal_corrupt` | Durable journal has a corrupt tail |
| `store_unavailable` | Durable store cannot be read or written |
| `writes_paused` | Reads work but writes are held |
| `spec_invalid` | Build-time specification failed validation |
| `dependency_unavailable` | Required capability unavailable; see `depends_on` |
| `unknown` | Cause cannot be classified |

The shared refusal encoder returns `error: "capability_unavailable"`, `capability`,
`state`, `reason`, `depends_on`, `revision`, and `boot_id`, with HTTP 409 or 503 for
`not_running`. Existing write endpoints retain their responses until they adopt it.

## Identity and privacy

First daemon boot creates `identity.json` in `$AIUR_BG_STATE_DIR/machine`, or
`${XDG_CONFIG_HOME:-~/.config}/aiur/machine` when that variable is unset.
The directory is private (0700) and the file is private (0600). `machine_id` is
128 random bits encoded as 26 lowercase Base32 characters, unrelated to hardware.

`instance_id` combines it with the launcher's instance key; moving the project root
changes that key. The default machine label is the first DNS label of the hostname.

An unreadable or damaged identity is never silently replaced. To reset deliberately,
stop all instances using this store, back up and remove its `identity.json`, then
restart. This creates a new machine identity and invalidates existing pairings.

The public report excludes provider diagnostics, filesystem paths, ports, tokens,
and credentials. The visible machine label is the hostname exception; repository
and Executor display identifiers are visible to authenticated clients.

## Client contracts

The private [`@aiur/contracts` package](https://github.com/aiur-team/aiur/tree/main/packages/aiur-contracts) provides generated TypeScript types, known capability IDs, harness ID patterns, and reason constants.

Its [v1 JSON Schema](https://github.com/aiur-team/aiur/blob/main/packages/aiur-contracts/schemas/capabilities.v1.schema.json) validates the daemon's golden report.
