# MP-E3 contract requests (for the coordinator)

Researched 2026-10-06 at `45a290e3`. MP-E3 owns no contract. MP-E3's needs from
the conversations contract were applied by its owner (MP-E4) directly; they
are not repeated here.

| ID | Target | Request / answer | Needed by |
| --- | --- | --- | --- |
| CR-E3-1 | MP-E7 CR-E7-2 | **Answered:** MP-E3-C5-T01 ships in wave 3 after MP-E7-C3 (RC-05) with `Executor.Send.capability/0` returning `{:unavailable, :executor_delivery_not_installed}` until MP-E7-C6 is present; the composer is disabled with that reason. No code change is needed when E7-C6 lands. | MP-E7-C6 |
| CR-E3-2 | MP-E7 CR-E7-3 | **Answered:** `Aiur.Executor.HookConfig.entries(harness, extra)` (MP-E3-C1-T04) accepts extra `%{event, command, timeout}` entries; MP-E7-C6-T03 adds its deliver hooks through it, and `uninstall/1` removes them by the same `AIUR_EXECUTOR_HOOK=1` marker. | MP-E7-C6-T03 |
| CR-E3-3 | MP-E7 CR-E7-5 | **Answered:** MP-E3 ticket IDs are two-digit (`MP-E3-C1-T01`). | MP-E7-C6 tickets |
| CR-E3-4 | `contracts/listener-mode.md` §8 / MP-E7-C6-T01 | The hook token is not at a literal `<executor-state-dir>/hook-token`: the executor state dir is per **repository** (`executor/state_paths.ex:33-45`), so two instances of one repo would share it. MP-E3-C1-T02 names files `<repo>.<instance_key>.executor.hook-{token,headers,url}`. MP-E7-C6 should read them through `Aiur.Executor.HookToken.path/0`, `headers_path/0`, `read/0`, never by a hard-coded path. | MP-E7-C6-T01/T02 |
| CR-E3-5 | `contracts/listener-mode.md` §8 / MP-E7-C6 | The hook command reads the daemon URL from the `…executor.hook-url` file at run time (MP-E3-C1-T04), because an Executor session outlives daemon restarts and the port can change. The deliver hook (E7-C6-T02, Node) should use the same file. | MP-E7-C6-T02 |
| CR-E3-6 | `contracts/harness-adapter.md` §6.8 (MP-R7) | The "attached" profile is defined by MP-E3 as: `Aiur.Executor.TranscriptIngest` + an extractor (`Claude.Transcript.extract_disk_record/2`, or the new `Codex.RolloutTranscript.extract/2`) over `Claude.TranscriptTailer`, which gains `from: {:offset, n}`, `on_offset` and `:extractor` options (MP-E3-C2-T01, C3-T02). R7 moves these, not rewrites them. | MP-R7-C4 |
| CR-E3-7 | `contracts/events-and-replay.md` §9 (MP-R2) | Confirms the reserved `executor.conversation.*` namespace stays unused: Executor chat is not on the bus. One new system alert topic is used: `system.executor.transcript.drift` (MP-E3-C2-T02); please add it to the R2 catalog with class `ledgered`. | MP-R2-C5 |
| CR-E3-8 | DESIGN-E3 (owner) | Decision needed before MP-E3-C1-T04: install Claude hooks into the repository's `.claude/settings.local.json` automatically on attach (proposed), or print-only. Codex is print-only either way (trust is interactive). | MP-E3-C1-T04 |
