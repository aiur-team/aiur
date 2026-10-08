---
ticket_id: MP-R2-C2-T05
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Put the debug event mirror behind an optional trace sink (no Phoenix.PubSub in the bus core)
status: ready
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T06]
prior_units: [U7, U8]
prior_boundaries: [BUS #10, TUI, OC]
prior_features: []
prior_findings: []
size_owner: EVENTS (publisher.ex 539, subscription_store.ex 748); re-check at start per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T05 — Trace sink for the debug mirror

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2.** No user-visible change: the `--debug`
  event ticker in the agent list, the per-agent `SessionWriter` marks and
  the chat-completions live bridge receive byte-identical
  `{:event_debug, entry}` messages on the same topics.
- **Deliverable:** `Aiur.Events.Trace` (behaviour + dispatch function) used
  by the bus core in place of `Aiur.Events.DebugLog.broadcast/3`;
  `Aiur.Events.DebugLog` becomes the default trace implementation and is
  no longer a bus-core member (contract rule R-5: PubSub topics stay with
  their owner).
- **Non-goals:** no change to `DebugLog`'s topics, entry shape or routing;
  no change to its subscribers; no rename of `Aiur.Events.DebugLog` (rename
  churn is out of scope, decisions RQ-8).

## Dependencies and blockers

DESIGN-R2 §1; C1-T06. File overlap with C2-T01 and C2-T03 on
`subscription_store.ex` (lines 425, 450) and C2-T03/T06 on `publisher.ex`
(lines 232, 268): one-line edits, merge in any order with a rebase.

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| `DebugLog.broadcast/3` (kinds `:publish | :receive | :read`) does `Phoenix.PubSub.local_broadcast(Aiur.PubSub, "aiur:events:debug", …)` plus a per-identifier topic; rescues everything | `src/lib/aiur/events/debug_log.ex:23,68-104,110-120` |
| Bus-core callers | `publisher.ex:232` (`do_publish`), `:268` (`publish_persisted`); `subscription_store.ex:425,450` |
| Non-bus callers (unchanged) | `agent_runner/events_digest.ex` (`:read` mark), subscribers `agent_list/app.ex`, `opencode/session_writer.ex`, `opencode/chat_completions/turn_stream.ex` (`git grep "DebugLog\.(subscribe|broadcast)"`) |
| Tests | `test/aiur/events/debug_log_test.exs`, `test/aiur/agent_list/debug_events_ticker_test.exs`, `test/aiur/agent_list/app_debug_events_persistence_test.exs`, `test/aiur/opencode/session_writer_test.exs` |

PROPOSED: `src/lib/aiur/events/trace.ex`, `src/test/aiur/events/trace_test.exs`.

## Chosen design

```elixir
defmodule Aiur.Events.Trace do
  @callback trace(kind :: :publish | :receive, topic :: String.t(), opts :: keyword()) :: :ok
  @spec trace(atom(), String.t(), keyword()) :: :ok
  def trace(kind, topic, opts) do
    case Application.get_env(:aiur, __MODULE__, :none) do
      :none -> :ok
      module -> module.trace(kind, topic, opts)
    end
  rescue
    _ -> :ok
  end
end
```

- Default (`src/config/config.exs`): `config :aiur, Aiur.Events.Trace, Aiur.Events.DebugLog`.
- `DebugLog` adds `@behaviour Aiur.Events.Trace` and
  `def trace(kind, topic, opts), do: broadcast(kind, topic, opts)`.
- The `rescue` matches `DebugLog.broadcast/3`'s own rescue
  (`debug_log.ex:101-104`), so a broken sink can never break a publish —
  same guarantee as today.
- `:read` stays a direct `DebugLog.broadcast/3` call from
  `events_digest.ex` (agent-runner, not bus).

## Implementation steps

1. Add `Aiur.Events.Trace`; config default.
2. `DebugLog`: behaviour + `trace/3` delegate (2 lines; file 121 lines).
3. Replace the four bus-core calls with `Aiur.Events.Trace.trace/3`
   (identical arguments); drop `DebugLog` from the aliases at
   `publisher.ex:41` and `subscription_store.ex:66`.
4. In the C1-T06 test (`test/aiur/events/bus_boundary_test.exs`), drop
   `debug_log.ex` from `@members` and delete its `Phoenix.PubSub`/`Aiur.PubSub`
   ratchet entry: `DebugLog` is now the default trace implementation outside
   the bus core (its manifest home is recorded by C2-T11; see
   CONTRACT-REQUESTS.md). The scan then proves `publisher.ex` and
   `subscription_store.ex` no longer reference `Aiur.Events.DebugLog`
   (add `Aiur.Events.DebugLog` to the scan's forbidden list).

## Non-happy paths

- PubSub not running (cold boot, test shutdown): unchanged, rescued.
- Trace sink `:none`: no debug ticker events; the bus works (reusable-bus
  shape). Not reachable with the default config.
- Performance: one extra `Application.get_env/3` per publish (an ETS read);
  negligible next to the existing `IdGenerator` GenServer call. No saving
  or cost claim is made.

## Compatibility and rollout

Internal app env only. Rollback: revert.

## Verification

1. `trace_test.exs` `"publish emits a :publish trace through the configured sink"` —
   app env → `FakeTrace` sending `{:trace, kind, topic, opts[:id]}`;
   `Publisher.publish("ticket.42.pr.opened", %{})` → `{:trace, :publish,
   "ticket.42.pr.opened", id}` with the returned id. **Fails without step 3**.
2. `"subscription delivery emits a :receive trace with the identifier"` —
   attached store, `set_enqueue_fn(fn _, _ -> :ok end)`, send event id 7 →
   `{:trace, :receive, _, 7}` and opts identifier = store id. **Fails without step 3.**
3. `"default sink keeps the debug topics byte-identical"` — default config;
   `Phoenix.PubSub.subscribe(Aiur.PubSub, "aiur:events:debug:42")`; publish
   `ticket.42.pr.opened` → `{:event_debug, %{kind: :publish, topic:
   "ticket.42.pr.opened", id: id, identifier: nil, body: %{}}}` (guards the
   delegate; fails if `trace/3` stops calling `broadcast/3`).
4. Existing debug tests listed above unchanged and green.

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/trace_test.exs test/aiur/events/debug_log_test.exs \
  test/aiur/agent_list/debug_events_ticker_test.exs test/aiur/agent_list/app_debug_events_persistence_test.exs \
  test/aiur/opencode/session_writer_test.exs test/aiur/events/bus_boundary_test.exs
```

Mutation check: revert step 3 only → tests 1–2 fail (FakeTrace receives
nothing because `DebugLog` is called directly); restore → pass.

Manual: covered by MP-R2-C4-T03's `aiurdev --debug` check (the agent-list
debug ticker still shows 💬/📬 marks; `log/record/chat.<issue>.ansi` is
unrelated).

## Completion and handoff

- [ ] No `DebugLog`/`Phoenix.PubSub` reference in `publisher.ex`, `subscription_store.ex`.
- [ ] Neither file grows.
- [ ] Docs: none.
- Dependents: C2-T11 (manifest: `debug_log.ex` assigned outside event-bus;
  see CONTRACT-REQUESTS.md), C4-T01.
