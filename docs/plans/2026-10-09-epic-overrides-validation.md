# Epic override validation — #3127

Final feature validation uses the configured integration branch `main`.

- Compile with warnings as errors, formatter check, strict lint: passed.
- Final scoped suite: 189 tests passed; after sync exception handling, all 24 store tests passed again.
- Restored mutation baseline: 113 tests passed. Focused development-shim control test: passed.
- npm launcher suite: 114 passed, 0 failed (`mise exec bun@1.3.14 -- bun test`).
- Component ownership, docs prose, configuration docs, bare assert_receive checks: passed. File-size passes against integrated base `3203ff8d6`; see current-base limitation below.
- The affected-test selector recommends full CI because launcher and manifest files changed; CI owns that gate.

## Mutation evidence

27 deliberate production mutations each caused collected test assertion failures.
Each batch asserted the intended worktree HEAD, clean status before mutation,
exactly the intended modified paths after mutation, and clean status after restoration.
The final mutation worktree head was `3f0912996`; its feature production code matches
`9f4a52c55` (the latter includes main integration). Per-case diffs and output are
retained in the ticket-private `epic-mutation-results` scratch directory.

Every new test, plus changed inventory and shim checks, failed under at least one
production mutation. The table identifies one observed failure per test.

| Collected test that failed | Production mutation |
| --- | --- |
| V-1 set journals every provenance field and deduplicates ids (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-11 corrupt file stays untouched and refuses all reads and writes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| V-12 newer version refuses load and preserves bytes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| V-13 foreign repository refuses load and preserves bytes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| V-14 unsafe symlink and oversized input are refused (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| V-15 absent server is unavailable (Aiur.BuildOrder.EpicOverridesTest) | `04-missing-empty` |
| V-16 failing writer leaves memory and generation unchanged (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-18 size cap preserves prior bytes and state (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-19 only committed changes broadcast (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-2 V-3 V-4 reject unknown, reserved and invalid batch inputs without writes (Aiur.BuildOrder.EpicOverridesTest) | `02-no-validation` |
| V-20 id cap allows 200 and rejects 201 atomically (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-21 unavailable show text and JSON never imply no override (Aiur.EpicCLITest) | `03-load-empty` |
| V-22 V-22b removed and unreadable catalog retain truthful known status (Aiur.EpicCLITest) | `07-config-fallback` |
| V-23 set JSON includes unchanged and previous actor (Aiur.EpicCLITest) | `09-cli-loses-previous` |
| V-24 CLI refuses agent identity sources and invalid actors (Aiur.EpicCLITest) | `10-cli-any-source` |
| V-25 batch command encodes actor and epic and normalizes hash ids (Aiur.EpicEngineTest) | `16-shell-wrong-dispatch` |
| V-25b list dispatch and help advertise epic commands (Aiur.EpicEngineTest) | `16-shell-wrong-dispatch` |
| V-26 all usage failures exit 64 before RPC (Aiur.EpicEngineTest) | `15-shell-no-validation` |
| V-27 V-28 actual executor binds string issue number, default ids and actor (Aiur.Codex.DynamicTool.EpicTest) | `11-tool-missing-number` |
| V-28 V-29b rejects provenance injection and conflicting arguments before setter (Aiur.Codex.DynamicTool.EpicTest) | `13-tool-ignores-conflicts` |
| V-29 backfill is unconfirmed and clear uses bound identity (Aiur.Codex.DynamicTool.EpicTest) | `11-tool-missing-number` |
| V-30 V-31 catalog reload is read on every write and errors never fall back (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-32 init survives bad state directory and unsupported tracker (Aiur.BuildOrder.EpicOverridesTest) | `06-init-healthy` |
| V-33 list uses configured keys in order and no fallback on config error (Aiur.EpicCLITest) | `07-config-fallback` |
| V-5 concurrent writes retain both entries and the later sequence wins (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-6 V-7 V-8 no-op is not journaled but source change confirms backfill (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| V-9 V-10 restart folds clears and preserves journal generation (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| bad next seq refuses load and preserves bytes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| complete but invalid journal entries fail closed without rewriting (Aiur.BuildOrder.EpicOverridesTest) | `24-invalid-complete-load` |
| epic override path honors override and decision-root isolation (Aiur.Config.PathsTest) | `18-path-shared` |
| first persisted assignment syncs its directory before acknowledgment, once (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| first-write sync failure makes uncertain durable state unavailable (Aiur.BuildOrder.EpicOverridesTest) | `01-no-batch-change` |
| malformed entry refuses load and preserves bytes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| stale-source control commands reuse a ready release without rebuilding (ScriptsAiurdevTest) | `25-shim-rebuild` |
| sync command launch exception leaves store alive and unavailable (Aiur.BuildOrder.EpicOverridesTest) | `27-sync-launch-exception` |
| unknown epic returns known keys to agent (Aiur.Codex.DynamicTool.EpicTest) | `11-tool-missing-number` |
| unknown op refuses load and preserves bytes (Aiur.BuildOrder.EpicOverridesTest) | `03-load-empty` |
| unsupported tools return a failure payload with the supported tool list (Aiur.Codex.DynamicToolTest) | `17-tool-unadvertised` |
| write timeout reports unknown outcome and identical retry is unchanged (Aiur.BuildOrder.EpicOverridesTest) | `23-source-noop-ignored` |

Exact commands, run from the isolated mutation worktree’s `src/`:

```sh
mise exec -- mix test --max-cases 4 test/aiur/build_order/epic_overrides_test.exs
mise exec -- mix test --max-cases 4 test/aiur/build_order/epic_overrides_test.exs test/aiur/epic_cli_test.exs
mise exec -- mix test --max-cases 4 test/aiur/codex/dynamic_tool/epic_test.exs
mise exec -- mix test --max-cases 4 test/aiur/config_paths_test.exs:23
mise exec -- mix test --max-cases 4 test/aiur/dynamic_tool_test.exs
mise exec -- mix test --max-cases 4 test/aiur/epic_cli_test.exs
mise exec -- mix test --max-cases 4 test/aiur_epic_engine_test.exs
mise exec -- mix test --max-cases 4 test/scripts_aiurdev_test.exs:431
```

## Review and limitations

Eight local review lenses completed; prior durability, parser-test and timeout
findings were fixed and independently checked. The cross-model job died without
result; no corroboration is claimed.

The expanded engine suite had two existing identity-fixture failures (lines 2039
and 3505); the same failures reproduced on base `2988a4eabba84983b4e334c53aa2371ef526b274`
in an isolated worktree. The temporary project walks into the enclosing dogfood
config on this host. They are outside the feature diff; CI remains authoritative.

The broad development-shim tests reached the agent manual-test guard. That path
was stopped; only the focused mocked control test continued. Real CLI/TUI manual
verification was not run because agent workspaces prohibit it.

Integration was performed once: pre-head `abf1f281c`, base `3203ff8d6`, merge
`2d32c6e46`. Rescue ref `rescue/3127-before-main-abf1f281` was pushed before resolving
manifest conflicts. Both the main projections dependency and epic ownership/API
paths were retained; the intended feature diff remains present.

## Resolved current-base gate

Main advanced to `85fbf331ae8d1675880fe5d79c4039f3a0ff2123` after the one permitted
integration. Its changed paths do not overlap this feature, and merge-tree is clean.
However, the required file-size checker compares all tracked files directly to the
current base and flags three unrelated files shortened by these newer commits:
`src/priv/static/dashboard.css` (10398 → 10409),
`src/test/aiur/extensions_test.exs` (1939 → 1940), and
`src/test/browser/fixture_server.exs` (2532 → 2646).
The feature docs are at 500 lines and pass. No unrelated file was changed to make
this gate green, and no second integration was attempted. The Executor authorized additional integrations whenever a required gate needs the current base.
An additional merge of `85fbf331a` resolved these comparisons, with rescue
`rescue/3127-authorized-main-2b9f87d8` pushed first. Feature scope is unchanged;
current-base file-size check now passes.
