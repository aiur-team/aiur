# The Stream Deck driver is the obvious first package

Operator's position, and the research agrees. This is the least contested
candidate in the spike and the only one with a deadline.

## Why it is obvious

It is already a separate package in a separate language with its own test suite,
and it **builds and tests green with no aiur present**. The question is not
whether it can be separated. It is where the line goes.

Measured:

| | |
| --- | --- |
| Modules that are pure driver | 26 of 37 |
| Runtime dependencies | one — `usb` |
| Driver-half dependency injection | complete (`src/runtime.ts:39-67`) |
| Standalone today | ~95% |

## The entire aiur coupling is three strings

Not a refactor. Three literals:

| what | where |
| --- | --- |
| lock name and a branded error | `packages/streamdeck/src/lock.ts:23,42-43` |
| `AIUR_STREAMDECK_BRIGHTNESS` | `packages/streamdeck/src/main.ts:125` |
| the systemd unit name | `packages/streamdeck/systemd/` |

Everything else that *looks* aiur-shaped is **type definitions, not calls**:
`AgentInput` at `src/keys.ts:43-53`, `src/mode.ts:89-91`, `src/dial.ts:124-150`,
`src/logs.ts:42-99`, and the touch-strip segment types. Those describe the shape
of data the binding layer supplies. They are not dependencies on aiur code.

## The one real gap

`src/index.ts:1-33` re-exports the driver layer and the aiur binding layer flat,
so **no boundary is enforced**. Nothing stops a future change from calling
across the line, and nothing would fail if it did.

That is the whole extraction: draw the line, enforce it at the export surface,
and move the three strings into the binding layer.

## What each half is

**Driver core** — talk to Stream Deck + hardware over hidraw or usb. Render key
bitmaps, the touch strip and dial input. Device discovery, hotplug, lifecycle,
suspend/resume recovery. Knows nothing about agents, tickets or fleets.

**aiur binding** — subscribe to a fleet, map agents to keys, map buckets to
colours, drive the three modes. Knows aiur.

The split is clean because the driver half was written to be driven, not to
drive.

## Why the timing matters

**PR #1603 is defining the artifact layout now** — `app/`, `runtime/`, `bin/`,
`share/`, `BUILD-INFO.json`, content-addressed by commit and sha256, published
as a GitHub Release asset.

Deciding *now* whether that archive contains one package or two is much cheaper
than re-cutting a published, immutable artifact later. This is not a request to
do the split inside #1603 — the gate in `README.md` stands. It is a request to
choose the layout with the split in mind and record the choice.

Note what #1603 does and does not do. It makes the sidecar **installable** —
bundled Node runtime, no toolchain prerequisite, reproducible tarball. It does
not make it **independent**: still `private: true`, no `bin` or `files` fields,
versioned off aiur's `v*` tags, built by aiur CI.

## Two drifts prove the boundary is not currently enforced

Both found by the spike, both verified, both now recorded on the parity tickets.

**Progress colour — same data, different meaning:**

```
src/priv/static/dashboard.css:7387   → var(--sd-accent)          # bucket accent
packages/streamdeck/src/keys.ts:108  → hsl((p/100)*125 72% 50%)  # red-to-green ramp
```

**`dependency_ready` — opposite fail direction:**

```
streamdeck_live.ex:315  → Map.get(agent, :dependency_ready, true)   # fail-open
keys.ts:121             → agent.dependency_ready === true           # fail-closed
```

For the same fleet state with that field absent, the emulator says unblocked and
the deck says blocked. Tracked on #1571 and #1584.

The bucket-to-visual token map is hardcoded **twice** with no shared source and
no parity test — running `#4fd6c4`, paused `#8fbcff`, stuck `#e3b341` with a
1.4s pulse, alert `#ff7b72` with a 1.6s pulse, queued `#c69bff`. Two of those
five have already drifted.

This matters for the packaging decision: publishing the driver separately makes
drift *harder to notice*, not easier. A parity test generated from one token
source is a precondition, not a follow-up.

## What is encouraging

The semantic contract is already correct and already shared.
`StreamDeckGrid.payload/2` emits pure tokens — `identifier`, `title`, `vendor`,
`bucket`, `progress_percent`, `priority`, `dependency_ready` — and `AgentInput`
in `keys.ts:43-56` matches those snake_case names byte for byte. Neither
renderer re-derives fleet state, and the emulator emits a bucket token as a CSS
class rather than a colour.

So the work is generating the token map from one source and adding the parity
test. It is not inventing a contract.

## One gap that affects the binding layer

The WebSocket channel carries `identifier, status, alert_count, title,
runtime_seconds, turn_count, work_state, pause_reason, tracker_paused, backend,
model` — and **no `bucket`, `progress_percent`, `priority` or
`dependency_ready`**.

The channel cannot drive keys today. Only the REST grid endpoint can. And
nothing in `packages/streamdeck/src/` fetches anything yet, so the contract is
typed but unwired. Tracked on #1583.

## Open question

Does the driver core get published to npm, or does it stay in-repo with an
enforced internal boundary?

The three-string coupling is small enough that either works. Publishing gets a
real external consumer — anyone with a Stream Deck + on Linux and Node. Staying
in-repo avoids a release cadence and version skew against the binding layer.

Worth deciding deliberately rather than by default.
