---
ticket_id: MP-R1-C2-T1
feature_id: MP-R1
chunk_id: MP-R1-C2
bucket: 1-refactor (Bucket-2 enabling work, RC-12)
title: Machine identity store created at first daemon boot (identity.json, no-clobber, no silent regeneration)
status: blocked
blocked_by: [DESIGN-R1]
prior_units: []
prior_boundaries: ["K #1 (Fs)", "#11 signal (attention)"]
prior_features: [MP-N2]
prior_findings: []
size_owner: "src/lib/aiur.ex: U8 package APP_BOOT (600 lines at release 0.0.7) — add at most 6 lines"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C2-T1 — Machine identity store at first boot

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1 (RC-12: Bucket-2 enabling work inside MP-R1),
  MP-R1, C2. Step S2. Contract: `contracts/identity-and-capabilities.md` §1.1, §4.
- **User value:** the machine gets one stable, private, random identity before any
  mobile feature exists, so capability reports and event envelopes can carry
  `machine_id`, and MP-N2 pairing builds on it instead of minting a second one (RC-01).
- **Deliverable:** PROPOSED `src/lib/aiur/identity/machine.ex` (`Aiur.Identity.Machine`)
  and `src/lib/aiur/identity/store.ex` (path resolution, read, no-clobber create);
  a 3–6 line call in `Aiur.Application.start/2`; a post-boot attention when degraded.
- **Non-goals:** `instance_id` (C2-T2), the capability report (C3), `machine_key`,
  devices, reset verb, label editing (all MP-N2), any CLI or docs page.

## Dependencies and blockers

- **DESIGN-R1 S3** (Kevin approves creating the file at first boot, label shown only in
  `aiur capabilities`). Implementation blocked until approved.
- **Concurrent:** C1-T*, C5-T*. **Dependents:** C2-T2, C3-T1, MP-N2 (reads the file).
- Contract request to MP-N2 (see `CONTRACT-REQUESTS-C1-C5.md` CR-R1-2): N2's store table must
  say R1 creates `identity.json` and N2 adds `machine_key_public`.

## Verified starting point (`45a290e3`)

- No machine identifier exists (searched `machine_id`, `host_id`, `/etc/machine-id` in
  `src/lib` and `packaging`).
- Boot sequence: `Aiur.Application.start/2` (`src/lib/aiur.ex:31-112`) runs best-effort
  writes before the supervisor: `record_daemon_start()` (`:50`),
  `Aiur.DaemonHeartbeat.write!()` (`:53`); the supervisor starts at `:105-108` with
  `|> tap(fn _ -> start_upgrade_check() end)` (`:109`) as the post-start hook precedent.
- Directory precedent: `Aiur.Upgrade.State.state_dir/0` (`upgrade/state.ex:35-40`):
  `AIUR_BG_STATE_DIR` else `$XDG_CONFIG_HOME/aiur` else `~/.config/aiur`. The launcher
  exports `AIUR_BG_STATE_DIR` (default `$config_home/aiur`, `aiur-engine.sh:281-298`);
  the agent-IR sandbox overrides it (`scripts/aiurdev:583`).
- `Aiur.Fs.atomic_write/3` (`fs.ex:18-33`) is rename-based, i.e. last-writer-wins; it
  cannot implement create-if-absent. `Aiur.Fs.sync_filesystem/0` (`fs.ex:86`) exists for
  first-creation directory durability.
- `File.ln/2` returns `{:error, :eexist}` when the target exists (verified locally,
  Elixir 1.19.5 / OTP 28, 2026-10-06; same as POSIX `link(2)` EEXIST).
- `Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)` is 26
  characters (verified locally).
- `:inet.gethostname/0` is already used for identity fallback (`executor/claims.ex:470-473`).

## Chosen design

```elixir
@spec ensure(keyword()) ::
        {:ok, %{machine_id: String.t(), machine_label: String.t(), created_at: String.t()}}
        | {:degraded, :identity_unreadable | :identity_uncreatable, detail :: term()}
def ensure(opts \\ [])          # opts: :dir (tests), :hostname_fun, :random_fun, :now
@spec current() :: {:ok, map()} | {:degraded, atom(), term()} | :not_loaded
```

- **Directory:** `opts[:dir]` > `Application.get_env(:aiur, :machine_state_dir)` >
  `$AIUR_BG_STATE_DIR/machine` > `${XDG_CONFIG_HOME:-~/.config}/aiur/machine`.
- **Read path:** file exists → parse JSON → validate `schema_version == 1` and
  `machine_id =~ ~r/^[a-z2-7]{26}$/` → `{:ok, …}`. Unknown fields ignored.
- **Create path:** file absent (`:enoent`) → `File.mkdir_p(dir)`, `File.chmod(dir, 0o700)`
  → write temp `identity.json.tmp.<unique>` with `:file.open([:write, :exclusive])`,
  chmod 0600, write, `:file.sync` → `File.ln(tmp, final)` → `File.rm(tmp)` →
  `Fs.sync_filesystem/0` once (first creation only) → re-read the final file (so the
  loser of a race returns the winner's identity).
- **Never regenerate:** any read error other than `:enoent`, invalid JSON, wrong
  version or malformed id → `{:degraded, :identity_unreadable, reason}`; the file is not
  touched. mkdir/write/link failure → `{:degraded, :identity_uncreatable, reason}`.
- **Result cached** in `:persistent_term` (`{Aiur.Identity.Machine, :boot_result}`); it
  is written once per boot (persistent_term writes are rare here).
- **Boot wiring** in `start/2`, after `record_daemon_start()`:
  `_ = Aiur.Identity.Machine.ensure()` (rescue-wrapped, never crashes boot). After the
  supervisor starts, extend the existing `tap` to also call
  `Aiur.Identity.Machine.announce_degraded/0`, which emits **one** attention
  `system.identity.unreadable` (or `.uncreatable`) through `Aiur.Alerts.emit_system/2`
  with `needs_attention: true` and a message naming the directory. After MP-R1-C5-T3 the
  call becomes `Aiur.Signal.alert/2` (C5-T5 migrates it).
- **Label:** first label of the hostname (`String.split(host, ".") |> hd`), max 63
  bytes, control characters stripped.

## Implementation steps

1. `identity/store.ex`: `dir/1`, `read/1`, `create/2` (no-clobber).
2. `identity/machine.ex`: `ensure/1`, `current/0`, `announce_degraded/0`.
3. `aiur.ex`: two call sites (≤ 6 lines). Do not move existing lines.
4. `src/config/config.exs` test env: `config :aiur, :machine_state_dir, <per-run tmp>`
   is **not** set globally; tests pass `dir:` explicitly, and the test-env boot uses a
   temp dir via `Aiur.TestSupport` (follow the existing per-case root pattern noted in
   `config/config.exs:140`) so `mix test` never writes the operator's home
   (AGENTS.md "Reading real state").
5. Add both files to `components.json` (`identity` component) if C1-T1 has merged.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Home read-only | `:identity_uncreatable`; boot continues; one attention |
| File corrupt / truncated | `:identity_unreadable`; file untouched; one attention; reset is MP-N2's explicit verb or manual deletion |
| Two daemons first-boot concurrently | `File.ln` race: one wins, both return the same id |
| Stale temp file from a crash | ignored (unique names); create path removes only its own temp |
| File owned by another user / mode wider than 0600 | read succeeds; mode is not changed by R1 (N2 owns hardening); logged at warning |
| `AIUR_BG_STATE_DIR` unset (release started by hand) | XDG fallback |
| Privacy | id random; no hostname-derived value except the operator-visible label |

## Compatibility and rollout

- New file on first boot of the new release. No migration. No config key.
- Rollback: revert; the file stays on disk harmlessly and is reused if re-deployed.
- DESIGN-R1 S3 is the only operator-facing decision.

## Verification

Test file PROPOSED `src/test/aiur/identity/machine_test.exs` (`async: true`, every test
uses `System.tmp_dir!/0`-based dirs via `dir:`):

| Test | Expected |
|---|---|
| `creates identity with 26-char base32 id, 0700 dir, 0600 file` | file exists; modes checked with `File.stat!/1` |
| `second ensure returns the same id and does not rewrite the file` | same id; `mtime` unchanged |
| `corrupt file is reported unreadable and left untouched` | `{:degraded, :identity_unreadable, _}`; bytes identical |
| `wrong schema_version is unreadable` | degraded |
| `concurrent ensure from 8 tasks yields one id` | all equal; one file |
| `unknown fields are preserved on read` | file with `machine_key_public` reads ok; file unchanged |
| `uncreatable dir is degraded, not raised` | dir under a 0500 parent → `:identity_uncreatable` |
| `announce_degraded emits exactly one attention` | inject emit fun; called once across two calls |

Command (worktree, isolated home; see README "Test command"):
`$TESTCMD test/aiur/identity/machine_test.exs test/aiur/application_test.exs`.

Mutation check: replace `File.ln` with `File.rename` → the concurrency test fails (ids
differ); make the corrupt branch fall through to create → the "left untouched" test
fails; drop the once-guard → the announce test fails.

Manual: start `scripts/aiurdev --test` (sandbox sets its own `AIUR_BG_STATE_DIR`);
confirm `<sandbox>/state/machine/identity.json` exists and `~/.config/aiur/machine/` was
not created by the test run.

## Completion and handoff

- [ ] DESIGN-R1 S3 approved.
- [ ] Store and boot wiring merged; tests fail under each mutation.
- [ ] No docs page in this ticket (the concepts page ships with C3-T3 and documents the
      file and its reset).
- **Dependents:** C2-T2, C3-T1, MP-N2 pairing tickets.
