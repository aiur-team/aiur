# Deferred findings

Discovered during research. Not in the active feature boundary. P0/P1 acceptance blockers found during execution are promoted; everything here stays deferred unless the operator promotes it.

| ID | Finding | Evidence | Suggested priority | Suggested disposition |
|---|---|---|---|---|
| DF-1 | Two daemons on one host that share a repo's executor directory can assign the same `wake_id`; the later record is dropped without a trace | `wake_id` from a boot-time counter (`src/lib/aiur/executor_wake_inbox.ex:134`, `src/lib/aiur/executor_wake_inbox/storage.ex:132`); duplicate ids skipped on append (`storage.ex:39-46`); directory keyed by repo only (`src/lib/aiur/executor/state_paths.ex:12-30`) | P2 (same-host only; this plan's instances are on separate hosts) | File as a bug: key the executor directory by instance, or allocate ids under the claims lock |
| DF-2 | `capacity_binding.ex` comments say the session cap does not persist; it has persisted since #5402 | `src/lib/aiur/orchestrator/capacity_binding.ex:249-252,288-291,302-303` vs `src/lib/aiur/orchestrator/slots.ex:65-76` | P3 | Fix the comments in any PR touching that file |
| DF-3 | Unknown keys in `.aiur/config` are dropped silently, so a misspelled key does nothing and says nothing | `src/lib/aiur/config/schema.ex:202-214` | P2 | Warn once per unknown key at load (MIC-007 closes this only for `aiur set`) |
| DF-4 | `#5939`-`#5954` bodies still contain unresolved `{T6}`, `{T9}` placeholders for their blockers | `gh issue view 5945` ("blocked by {T6}"), 5948/5950 ("blocked by {T9}") | P2 | Executor replaces placeholders with issue numbers (T6 = #5942, T9 = #5947) when it next edits those tickets |
| DF-5 | `aiur listen` streaming over HTTP | `packaging/npm/aiur-cli/libexec/engine/control.sh:445-464` | P3 | Revisit with #5695 (outbound event stream) |
| DF-6 | Local control calls are not audited; only remote calls are | design scope | P3 | Revisit if operators need one audit trail |
| DF-7 | Compare-and-set for concurrent `aiur set` writers | design scope | P3 | Add `--expect-revision` if two operators collide |
| DF-8 | No idempotency key on control calls: a 504 on a write leaves the outcome unknown, and a manual retry can send a second `message` or `queue add` | KTD1, KTD4 (round-2 review) | P3 | Add an optional `request_id` with a short server-side dedup window if retries cause duplicates; v1 clients never retry writes |
| DF-9 | An agent on the Executor machine that can read the Executor's process environment still sees `token_env` write tokens | round-2 review; MIC-003 scrubs only inherited agent environments | P3 | Run the fleet Executor outside agent workspaces; revisit with OS keychain storage if needed |
