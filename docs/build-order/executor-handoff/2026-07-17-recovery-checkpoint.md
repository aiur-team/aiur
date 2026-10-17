## Recovery checkpoint (updated 2026-07-17 06:59 PDT)

This checkpoint supersedes the older live-state narrative below. The former
Claude Executor is not being restarted. Its exact local session was recovered
as `f6f086dd-48ba-4e9e-aa9e-7a703b96a778` from
`~/.claude/projects/-home-orangekid-github-aiur/f6f086dd-48ba-4e9e-aa9e-7a703b96a778.jsonl`,
and its live issue/PR ownership was reconciled against GitHub, the per-issue
workpads, and both workspace logs before dispatch resumed.

The recovered Claude workflow was `wyxa8n3xw` / local run
`wf_9fed8f61-e34` (`refresh-review-prs`). Its final concrete lanes were
#1105/PR #1209, #1124/PR #1208, #1214, the Credo 200-column alignment, and
the distribution-gated #1119. Reconciliation proves the first four were
finished after Claude stopped: PRs #1209 and #1208 merged to `develop`, #1105,
#1124, and #1214 are closed `agent:done`, and the Credo fix merged through
#1226/#1227. Do not restart or duplicate those old workers. #1119 is the only
surviving old lane and remains intentionally paused at the package-publication
gate described below.

Aiur is now **running Codex-only** from the literal `develop` branch in the
fresh canonical runtime checkout `/home/orangekid/github/aiur-runtime-develop`.
The Executor force-built `scripts/aiurdev` first, removed 18 leaked test-only
`opencode serve` process groups, and launched the background daemon with a
sixteen-worker ceiling. The checkout and authoritative remote tip are exact
`develop@6afa161230b4349543c039a6b8b6abcc9218ba07`; Claude fallback is empty.
The dashboard is healthy on loopback. The requested Tailscale bind was not used
because neither dashboard-auth environment variable was present; do not invent
credentials or restart the healthy daemon only to change that listener.

The recovered fleet began with nine one-writer Codex owners. Two infrastructure
lanes have now merged, while the surviving feature owners remain isolated:

- BO-011/#1098 / draft PR #1233;
- DASH-003/#1110 / draft PR #1234;
- DASH-009/#1115 / draft PR #1204;
- DASH-010/#1116 / paused draft PR #1232;
- DASH-014/#1120 / draft PR #1239;
- DASH-026/#1130 / PR #1217; and
- DASH-029/#1133.

Three Codex-only P1 stability owners are also live: #1237 fences stale
lifecycle writes and distinguishes queued from provider-delivered Executor
messages; #1238 recovers queued Codex turns after the app-server port closes;
and #1240 prevents DecisionStore enrichment from redispatching already-answered
decisions.

The Executor also triaged the newly confirmed full-suite monitor race #1235 as
a narrow Ad Hoc stability lane. Its one-file fix passed 25 focused repetitions,
the complete GraphProjection file, independent review, and every CI job; PR
#1236 squash-merged as `develop@6afa161230b4349543c039a6b8b6abcc9218ba07`,
and #1235 was explicitly closed `agent:done`. At that checkpoint no additional
Build Order ticket was queued. Load reached 16.68 on 12 CPUs during the earlier
base-sync wave and is now below one core per CPU. DASH-010/#1116 has since
released its owner slot at the no-Claude manual gate, so DASH-009/#1115 resumed
as the fifth active owner and PR #1204 returned to draft exact-base rework
against `6afa1612`.
Preserve one writer per workspace. After every `develop` merge, send the exact
new base to all owners and stop reviewing their now-stale heads until they push
replacements.

The first convergence lane is complete: PR #1213's one-file global-log test
isolation passed every exact-head CI job and six independent Compound
Engineering review lenses plus its prior-comment gate. It squash-merged as
`develop@59e9a2d5f002e3381ee49e8e88fe12598af4925f`, and #1149 was explicitly
closed with `agent:done` because `develop` is not the default branch. All other
PR heads became stale at that instant. #1036's prior exact head was `ab94042b`,
#1204's was `0fdb7e4c` (with a ticket-local lint failure), and #1217's remote
head was still `c2e67acd`; their owners were told to preserve scope, integrate
exact `59e9a2d5`, and publish replacement heads before Executor review.

The second convergence lane is also complete. The Executor took over #1036 in
an isolated checkout, repaired its asynchronous admission, daemon-owned outcome
trust boundary, schema migration, retry coalescing, attention ordering, and JSON
primitive handling, and published final head
`883e03f107aff8aa1b78212687b4076e8bb3ee9e`. Independent correctness, security,
and reliability reviews found no remaining issue; every exact-head CI job and
both regression guards passed. PR #1036 squash-merged as
`develop@01a9fc8849044edbaf0663c9852c937d5c709904`, and #1031 was explicitly
closed with `agent:done`. The live owners received that exact replacement base
through Aiur's Executor-message path. DASH-010 immediately published replacement
head `ba666dbb964450a2a7d2c561fbda8c5182771864` and restarted CI; DASH-026 is
integrating it. BO-011 remains green at `07ffcfcd` but now needs an exact-base
integration before merge.

Feature review is active rather than ceremonial. Exact-head Compound
Engineering review returned BO-011/#1098 to rework with five confirmed
security, accessibility, identity, reconnect-token, and truthful-truncation
defects. Its owner published replacement head
`aff1f7f7c83ae044c5d47a5011888d98407fee3b`: build, lint, guard, full test,
browser, and layout jobs are green, but Dialyzer found two ticket-local
unreachable patterns at `ticket_context_adapter.ex:139` and
`build_order_presenter.ex:906`. The exact repair packet is PR comment
`5003865397`; keep the PR draft until a replacement head passes Dialyzer and
fresh delta review. DASH-010/#1116 repaired all
four confirmed source-accounting/coverage/time/identity defects at `cf1d61fa`;
three independent re-review slices are clean and the complete test job passed.
Its one-file Credo follow-up is pushed as exact head
`612e3cb7e2e21b62d354c27c12853ac543956faf`, with lint and every short CI job
plus the complete test job green. PR #1232 remains draft with
`agent:ci-wait` preserved under `agent:paused`: code is qualified, but the
required real synthetic-safe Claude REPL/Remote Control proof has no honest
quota-free substitute, and Claude must not be launched while the operator's
no-Claude usage-limit instruction is active. DASH-003/#1110 is full-CI green
at `ef469502` but returned to draft
rework for nine exact-head identity, announcement, count-truth, truncation,
exact-navigation, touch-target, cache-fencing, subscription-lifecycle, and
provider-outage command-truth defects. DASH-026/#1130 passed all CI at
`390f2137` before #1236,
then returned to rework for the test-only base advance and ten confirmed
exact-head review defects: prompt/response chronology, authoritative
worker-generation and runtime-status fences, restart cache reset, Remote
Control backfill and cold-start delivery loss, replay identity beyond visible
retention, stable Claude disk-record identity, complete capability-URL
redaction, and bounded runtime-status fanout. PR #1217 is draft until an
exact-base replacement fixes all ten, passes fresh CI, and survives exact-head
re-review.

DASH-009/#1115 is now authoritatively back in `agent:rework`. PR #1204 exact
head `5cf41c08cde489dc109e0355c84bd77b4e701fd1` contains exact
`develop@6afa1612` and every centralized CI job is green, but three independent
Compound Engineering reviews plus the Executor found nine blockers. The P1s
are: durable dedup ignores DASH-008's stable `idempotency_key` and can count one
event twice when mutable model/source context changes; `update_kind: :partial`
can report full raw coverage; and checkpoint/segment/torn recovery mutates the
active authority before durably publishing its degraded marker, so a crash can
reboot healthy/writable after acknowledged history disappeared from the active
segment. Six P2 prefix-retention, quarantine, call-timeout, numeric-bound, and
append-scaling findings are in PR comment `5004008587`; issue comment
`5004011243` is the durable rework handoff. Keep #1204 draft and do not attempt
the Executor-only synthetic daemon/TUI gate until a replacement head clears
focused review and fresh CI. The Executor message was accepted into AgentChat
but has not yet been proven provider-delivered; the tracker label was verified
after the authoritative write.

DASH-014/#1120 published exact-base draft PR #1239 at
`b3ae911de08fe97018b6afcbe1ac8dd6609d54d4`. Its first full-test job failed
only untouched `BranchRefStoreTest`; the rerun and every other exact-head CI
job are now green. Three independent reviews plus the Executor nevertheless
found ten production blockers independent of that flake. The P1 set is:
production status snapshots can never make the summary
fresh; terminal complexity becomes permanently stale and then silently
defaults to weight 1 after same-run owner restart; serial in-owner source reads
can block the read API beyond its timeout; forbidden workspace/message/session
facts are retained; exact progress ignores unhealthy weight evidence; and
outcome LKG omits the membership-generation fence. Four P2
freshness/generation/performance/decomposition findings are in PR comment
`5003844613`. #1120 is authoritatively `agent:rework`. Its unchanged head was
later marked ready by a stale lifecycle/CI transition; the Executor converted
it back to draft and recorded the correction in PR comment `5004023349` while
the existing Codex owner began a new rework turn. This is live corroboration for
#1237's lifecycle-generation fence.

The #1098/#1130 rework regressions are now a confirmed P1 orchestration defect,
tracked as queued stability lane #1237. Accepted Executor messages can remain
undelivered to the provider while an old worker turn continues: #1130's review
waited 2,110,645 ms before provider delivery, and both tickets received an
unfenced lifecycle write that replaced newer authoritative `agent:rework` with
`agent:ci-wait`. Tracker and CI handoff transitions have no expected-state or
lifecycle-generation fence, while the rendered user transcript currently proves
enqueue acceptance rather than delivery. #1110 separately exhausted three
retries in the same queue-drain subsystem after closed-port `turn/start` writes
and a turn-ID mismatch; its preserved workspace is running again in rework.
Until #1237 lands, verify the tracker label after every in-flight review
intervention and never treat an old turn's CI-wait transition or optimistic
Executor transcript as authoritative delivery evidence.

#1238 is the concrete closed-port companion to #1237. #1110 exhausted all
three retries after `port_command` wrote `turn/start` to a dead app-server,
then QueueDrain hit a turn-ID mismatch and `{:error, :unavailable}`. The
Executor restored #1110 through authoritative `agent:rework` without replacing
its workspace; #1238 now owns restart-safe queued-turn recovery. Its focused
implementation and directly related tests are passing and it is preparing a
draft PR, but no remote head existed at this checkpoint. #1240 owns a separate
exact-`develop` DecisionStore race: the answered-decision enrichment test
reproduced an unexpected second dispatch in 3/5 isolated serial seeds and its
owner is tracing the existing reconciliation scheduler before changing code.
Do not repair either control-plane defect inside feature workspaces.

At 06:58 PDT a lightweight `aiurdev agents` RPC timed out while both build-gate
slots were occupied by large focused suites. Direct process inspection proved
the canonical release BEAM, instance-keyed tmux session, owners, and test
processes were all still live and advancing; only the bounded RPC helper was
terminated. Do not restart the daemon for that saturation symptom. Wait for the
current build-gate holders to drain, then retry one lightweight control call.

DASH-013/#1119 remains source-complete as draft PR #1228 at
`6f5696828cb54f775623299cc61c1067ef2b2810`, with full CI green and independent
review clean. It carries `agent:paused` and must **not** merge until
`aiur-claude@1.1.0` is published and installed from sibling source commit
`e555b8dd61c0af4cc18a6061fd278da05b9bc9f8`. The npm registry still exposes
only 1.0.0 and this machine has no publish authority.

Two control-plane symptoms were separated. Ordinary control recovers after
startup pressure settles; the one `set max-agents` timeout was fleet/GenServer
saturation, not a recurrence of #627. By contrast, `watch --full` and
`alerts --needs-attention` synchronously scan roughly 19 GiB of historical
workspace NDJSON and time out deterministically. That distinct bug is paused
as #1231 outside the 54-ticket Build Order denominator. Until fixed, use direct
workspace logs, GitHub state, and the lightweight local alert tailer; do not run
the full-history alert commands.

The documentation checkout remains branch
`executor/build-order-live-handoff-20260715` with intentional machine-only
`.aiur/config`, `.aiur/model-usage.json`, caches, and crash-dump residue. Commit
only the handoff/chat/preview files. The old accidental runtime merge was
preserved non-destructively at
`/home/orangekid/github/aiur-runtime-develop-preserved-20260717`; never push or
destructively reset it.
