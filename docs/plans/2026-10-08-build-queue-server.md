---
artifact_readiness: implementation-ready
---
# Build queue reconcile server

Source: issue #3056 and MP-E1-C3-T03 at 930e689c. Dependencies are present in this checkout.

## Scope and decisions

Own the protected named Hints table in a supervised GenServer. Gate boot on recording, enabled configuration and tracker label capability. Unsupported direct starts stay inert. Store recovery failure exposes store_unavailable with neutral hints. Events and open-issue signals coalesce over two seconds; periodic ticks retry Exchange subscription and reconcile even without signals. Explicit requests use the same coalescing path.

Use real Planner and snapshot facade, Store, ClaimProbe and injectable clock. Missing closed issue evidence stays unknown: later C4 supplies those reads. Record latest planned actions without label writes or fabricated promotion provenance. Repeated plans can repeat a proposed promotion until actual labels change; exactly-once label effects belong to the executors. No CLI or placeholder show API: expose useful read-only projections for the downstream CLI.

## Implementation units

1. Add src/lib/aiur/build_queue.ex facade and src/lib/aiur/build_queue/server.ex lifecycle. Extract observation/planner/hint assembly into src/lib/aiur/build_queue/reconcile.ex. Wire one gated child in src/lib/aiur.ex without growing that oversized file. Ensure components.json owns the facade.
2. Add src/test/aiur/build_queue/server_test.exs with boundary fakes and causal barriers: unsupported and disabled startup, corrupt store, protected ownership and cleanup, debounce, real Exchange binding, fallback timer scheduling and repeat ticks, snapshot changes, ordering and stale-row removal, unavailable claims. Add separate boot gate tests to avoid growing oversized application tests.

## Risks and validation

Named ETS requires non-async tests. Timer tests inject scheduling and deliver the scheduled messages, never sleep. Unknown observations never invent closed state or remove holds. A no-op executor must not suppress unexecuted actions. Subscription identity is monitored so Exchange replacement rebinds on the next tick.

Run compile with warnings as errors, formatting, affected tests with max-cases 4, lint, bare-receive and committed file-size gates. Mutate each behavior in an isolated worktree and assert only intended production changes before running the tests. Manual sandbox CLI launch is prohibited inside agent workspaces; report that limit. Review the diff and PR claims before ready/CI handoff.
