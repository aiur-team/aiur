---
title: "fix: Prewarm clone auth + actionable warm-base failure handoff + detect-and-disclose"
date: 2026-06-29
type: fix
status: ready
---

# fix: Prewarm clone auth + actionable warm-base failure handoff + detect-and-disclose

## Summary

The warm-base (prewarm) build during `aiur init` cannot clone a private repo: it
builds a plain `https://github.com/<repo>.git` URL and shells out to `git` with
no credential, so private repos fail with exit 128 (`Password authentication is
not supported` / `could not read Username … Device not configured`) even though
`GITHUB_TOKEN` is loaded in the process environment. When that build fails, the
only feedback is a one-line "retries on the next run" — no diagnosis, no
self-serve fix, no AI handoff. Separately, toolchain detection silently collapses
polyglot/oddly-shaped monorepos to a single build root and reports genuine misses
and genuine ambiguity with the same `:none`.

This plan fixes the auth bug (the actual blocker), turns the runtime
warm-base failure into an actionable report (human self-resolution steps **plus**
a ready-to-paste AI prompt embedding the real failure output), and makes
detection distinguish "found nothing" from "found several" so init can disclose
the candidates instead of misreporting "couldn't auto-detect" — while adding
Swift/CocoaPods manifests for iOS visibility.

---

## Problem Frame

Three defects, surfaced by `aiurdev init` against a private polyglot monorepo
(`its-everdred/biobreath_v2`: web at root + `mobile/` Expo + `watchos/` Swift):

1. **Auth (blocking).** `Aiur.RepoBase.resolve/0` hardcodes an HTTPS clone URL and
   `git/2` runs `System.cmd("git", …)` with no credential. Git never reads
   `GITHUB_TOKEN`; the private clone 401s, and with no TTY it can't prompt.
2. **No failure handoff.** The AI-handoff prompt
   (`print_prewarm_fallback`/`prewarm_fallback_prompt`) is wired only to the
   detection-miss `:none` branch in `resolve_prewarm/2`. The runtime clone/build
   failure path (`maybe_first_prewarm/4`) just prints
   `⚠️ Warm base build failed (reason); it retries…`.
3. **Detection conflates miss vs. ambiguity.** `Aiur.Prewarm.Detect.detect/1`
   returns `:none` both when nothing is found and when several lockfile-backed
   languages tie. iOS/Swift toolchains are invisible (not in `@manifests`).

---

## Requirements

- **R1** Warm-base `git clone`/`ls-remote`/`fetch` authenticate with the resolved
  GitHub token for private repos, without writing the token into the cloned
  `.git/config` or into process argv (no `ps`/log leak).
- **R2** When no token is available, git fails fast with a clear error instead of
  hanging on a credential prompt.
- **R3** On warm-base build/clone failure during init, the user sees (a)
  failure-class-specific self-resolution steps and (b) a ready-to-paste AI prompt
  containing the captured failure output.
- **R4** Detection distinguishes a genuine miss from an ambiguous multi-candidate
  result; init discloses the candidate list on ambiguity rather than printing
  "couldn't auto-detect".
- **R5** Swift (`Package.swift`) and CocoaPods (`Podfile`) are detectable
  manifests so iOS subtrees are visible to detection/ambiguity logic.
- **R6** No regression to the existing happy paths (public-repo clone, single-root
  detection, `:none` true-miss fallback). Existing tests stay green.

---

## Key Technical Decisions

- **KTD1 — Auth via env-injected git config, not URL or `.git/config`.**
  Pass credentials to each networked git call through environment variables that
  set a per-host HTTP header:
  `GIT_CONFIG_COUNT=1`,
  `GIT_CONFIG_KEY_0=http.https://github.com/.extraheader`,
  `GIT_CONFIG_VALUE_0=AUTHORIZATION: basic <base64("x-access-token:" <> token)>`,
  plus `GIT_TERMINAL_PROMPT=0`.
  *Rationale:* This is the GitHub-Actions-standard mechanism. Env-based config
  (vs. `-c key=value` on argv) keeps the token out of `ps`/argv; a clean origin
  URL keeps it out of the persisted `.git/config`; per-host scoping
  (`http.https://github.com/.`) confines the header to github.com. Works on Linux
  CI where SSH keys are absent. `GIT_TERMINAL_PROMPT=0` satisfies R2.
  *Alternative rejected:* `https://x-access-token:TOKEN@github.com/...` — persists
  the token in origin and leaks via argv.

- **KTD2 — Apply auth env to all `git/2` calls in `repo_base.ex`.** Thread the env
  through the single `git/2` helper so clone, ls-remote, fetch, and the local
  rev-parse/reset calls all carry it. The header is HTTP-transport-only, so it is
  inert for local operations — simpler than selectively tagging network calls.

- **KTD3 — Failure report is classified, with one rich AI prompt.** Classify the
  reason tuple into `:auth | :clone | :build | :other` (auth detected by scanning
  the captured stderr). Emit tailored human steps per class, then a single AI
  prompt that embeds repo, the `base_build` command, and the trimmed failure
  output. One prompt (not three) — the agent reads the embedded error and acts.

- **KTD4 — Extend `Detect.detect/1` return with `{:ambiguous, candidates}`.**
  Keep `{:ok, …}` and `:none` (true miss) intact; add a third arm carrying the
  competing `{language, build_root}` candidates. Only `resolve_prewarm/2` and
  `detect_test.exs` consume the return, so the surface is contained.

---

## Implementation Units

### U1. Authenticate warm-base git operations

**Goal:** Private-repo warm-base clone/fetch/ls-remote succeed using the resolved
GitHub token; fail fast (no prompt) when no token.
**Requirements:** R1, R2, R6
**Dependencies:** none (do first — unblocks manual verification of everything else)
**Files:**
- `src/lib/aiur/repo_base.ex` (modify)
- `src/test/aiur/repo_base_test.exs` (modify/add)

**Approach:**
- Add a private `git_auth_env/0` that reads `Aiur.GitHub.Config.token/0` and
  returns the `GIT_CONFIG_*` + `GIT_TERMINAL_PROMPT=0` tuples per KTD1; when no
  token, return just `[{"GIT_TERMINAL_PROMPT", "0"}]`.
- Thread the env into `git/2` (KTD2): both clauses pass
  `env: git_auth_env()` to `System.cmd` (merges with, not replaces, the OS env).
- Leave `resolve/0`'s clean HTTPS URL unchanged — auth rides in the env, origin
  stays clean.
- Keep the token out of any `Logger`/error string (`format_error/1` already trims
  captured stdout/stderr, which never contains the env value).

**Patterns to follow:** existing `git/2` (`repo_base.ex:317-318`); `Base.encode64`
usage in `lib/aiur/http_server.ex`; token access via `Aiur.GitHub.Config.token/0`.

**Test scenarios:**
- With a token configured (stub `GITHUB_TOKEN` env / persistent_term), the env
  list returned for a git call includes `GIT_CONFIG_COUNT=1`, the
  `http.https://github.com/.extraheader` key, a value beginning `AUTHORIZATION: basic `,
  and a base64 segment that decodes to `x-access-token:<token>`.
- With no token, the env list contains `GIT_TERMINAL_PROMPT=0` and no
  `GIT_CONFIG_*` keys.
- The synthesized header value never appears in argv (assert the clone is invoked
  with a clean URL and no `-c` token arg) — guards the no-`ps`-leak property.
- Regression: a public clone path (existing test, if any) still succeeds.

**Verification:** `mix test test/aiur/repo_base_test.exs` green; manual `aiur init`
in a private repo with a valid `GITHUB_TOKEN` clones the warm base.

---

### U2. Actionable warm-base failure report (human steps + AI prompt)

**Goal:** Replace the bare failure line in `maybe_first_prewarm/4` with a
classified report carrying self-resolution steps and a paste-ready AI prompt.
**Requirements:** R3, R6
**Dependencies:** none functionally; land after U1 so the common auth case is
already fixed and this handles the residual failures.
**Files:**
- `src/lib/aiur/init.ex` (modify)
- `src/test/aiur/init_test.exs` (modify/add)

**Approach:**
- Replace the single `io.puts` at the `{:error, reason}` arm with
  `report_prewarm_failure(io, repo, cmd, reason)`.
- Add `classify_prewarm_failure/1`: `:auth` when a clone/fetch/reset reason's
  captured output matches auth signatures (`authentication failed`,
  `could not read username`, `invalid username or token`,
  `password authentication`, `terminal prompts disabled`); `:clone` for other
  clone/fetch/reset failures; `:build` for `:base_build_failed`; `:other`
  otherwise.
- Add `prewarm_failure_guidance/2` returning class-specific human steps (auth →
  check `GITHUB_TOKEN` validity + scope + account access; clone → repo
  visibility/network; build → the `base_build` command failed, run it in a clean
  checkout). Keep concise, mirror existing `io.puts` iodata style and `dim/1`.
- Add `prewarm_failure_prompt/3` embedding repo, `base_build` cmd, and the trimmed
  failure output (reuse the `format_error`-style 1500-char trim), instructing an
  agent to diagnose (auth/toolchain/build), fix config or report the needed
  secret, and verify locally. Reuse the framing of the existing
  `prewarm_fallback_prompt/0`.
- Always append "also retries automatically on the next `aiur` run."

**Patterns to follow:** existing `print_prewarm_fallback/1` +
`prewarm_fallback_prompt/0` (`init.ex:734-787`); `dim/1` (`init.ex:1276`);
`maybe_first_prewarm/4` io shape.

**Test scenarios:**
- `classify_prewarm_failure/1`: `{:repo_base_clone_failed, 128, "...Authentication failed..."}`
  → `:auth`; `{:repo_base_clone_failed, 128, "fatal: repository not found"}` →
  `:clone`; `{:base_build_failed, 1, "..."}` → `:build`; an unrecognized tuple →
  `:other`.
- `report_prewarm_failure` (capture io): auth failure output contains a
  `GITHUB_TOKEN` self-resolution hint AND the paste-ready AI prompt block AND the
  embedded failure-output snippet.
- Build failure output references the `base_build` command and routes to the AI
  prompt.
- The retry sentence is present in every class.

**Verification:** `mix test test/aiur/init_test.exs` green; injecting a failing
`prewarm_build` dep yields the classified report in captured output.

---

### U3. Detect-and-disclose + Swift/CocoaPods manifests

**Goal:** Detection separates genuine miss from ambiguity and surfaces iOS
toolchains; init discloses candidates instead of "couldn't auto-detect".
**Requirements:** R4, R5, R6
**Dependencies:** U2 (reuses the AI-handoff disclosure path / `dim` style in init)
**Files:**
- `src/lib/aiur/prewarm/detect.ex` (modify)
- `src/lib/aiur/init.ex` (modify `resolve_prewarm/2`)
- `src/test/aiur/prewarm/detect_test.exs` (modify/add)
- `src/test/aiur/init_test.exs` (modify/add)

**Approach (detect.ex):**
- Add manifests: `{:swift, ["Package.swift"]}`, `{:cocoapods, ["Podfile"]}`; add
  lockfiles `swift: ["Package.resolved"]`, `cocoapods: ["Podfile.lock"]`.
- Add `command_for/2` clauses for the new languages
  (`swift` → `mise exec -- swift build`; `cocoapods` → `mise exec -- pod install`)
  so a *single* iOS candidate still yields a usable command.
- Change `select/1`: when zero candidates → return a miss signal; when exactly one
  (or one lockfile-backed winner) → `{:ok, …}`; when several lockfile-backed
  candidates tie → return `{:ambiguous, [{lang, rel_root}, …]}` instead of `nil`.
  Update `detect/1` to map: miss → `:none`, ambiguous → `{:ambiguous, candidates}`,
  single → resolve as today. Build the relative roots via the existing
  `relative_root/2`.
- Update the `@type result` typespec and `@moduledoc` to document the new arm.

**Approach (init.ex `resolve_prewarm/2`):**
- Add an `{:ambiguous, candidates}` arm that prints a disclosure ("Found multiple
  build roots: …; pre-warm needs one command") then routes to the existing AI
  prompt (reuse `print_prewarm_fallback/1`, optionally noting the candidates), and
  returns `%{enabled: false, base_build: nil}` (same as `:none` today).
- Keep the `:none` arm as the true-miss message.

**Patterns to follow:** `@manifests`/`@lockfiles` tables and `select/1`/`has_lock?/2`
(`detect.ex:21-124`); `resolve_prewarm/2` arms (`init.ex:709-732`).

**Test scenarios (detect):**
- `Package.swift` + `Package.resolved` alone → `{:ok, %{language: :swift}}` with
  `swift build`.
- `Podfile` + `Podfile.lock` alone → `{:ok, %{language: :cocoapods}}` with
  `pod install`.
- Two lockfile-backed languages at the same depth (e.g., node+go, the existing
  ambiguity fixture) → `{:ambiguous, candidates}` where candidates lists both
  languages — **replaces** the current `:none` assertion in that test.
- No supported manifest → still `:none` (true miss preserved).
- Existing single-language and workspace cases unchanged (regression).

**Test scenarios (init):**
- `resolve_prewarm` with a stubbed `detect_toolchain` returning
  `{:ambiguous, [...]}` → output discloses the candidate roots AND emits the AI
  prompt; returns prewarm disabled.
- `detect_toolchain` returning `:none` → unchanged "couldn't auto-detect" path.

**Verification:** `mix test test/aiur/prewarm/detect_test.exs test/aiur/init_test.exs`
green; updated ambiguity test asserts the new shape.

---

## Scope Boundaries

**In scope:** the three defects above and their tests.

### Deferred to Follow-Up Work
- **Multi-root `base_build`** (run several build roots for a polyglot repo) — the
  real fix so pre-warm serves all subtrees of a monorepo, not just one. Larger:
  config schema (`base_build` as a list), `repo_base` build loop, init prompt.
  Tracked separately (Thread 1-A from the spike).
- Applying the same token-injection to the agent-workspace clone hook
  (`workspace.ex` `hook_env/0` only exports `THIS_REPOSITORY_URL`). Same root
  shape; out of scope for this PR.
- Expo/React-Native-specific detection (deps-sniffing `package.json`), and Xcode
  project/workspace (`*.xcodeproj`) detection beyond SPM/CocoaPods manifest files.

### Non-goals
- Changing the prewarm copy-on-write/materialization mechanics.
- Reworking `Aiur.GitHub.Config` token resolution.

---

## Risks & Mitigations

- **Token leak.** Mitigated by env-based config (no argv) + clean origin URL +
  trimmed error strings. Test asserts no token in argv.
- **`GIT_CONFIG_COUNT` collision** with an inherited value. Low risk in aiur's
  controlled subprocess env; we set it explicitly to `1`.
- **Detect return-type change** breaking a consumer. Contained: only
  `resolve_prewarm/2` + `detect_test.exs` consume it; the ambiguity test is
  updated in the same unit.
- **Over-eager auth classification.** Auth signatures are matched case-insensitively
  against captured stderr; a non-auth clone error falls through to `:clone` (still
  actionable), so misclassification degrades gracefully.

---

## Verification (whole change)

From `src/`: `mix format`, `mix lint`, and
`mix test test/aiur/repo_base_test.exs test/aiur/init_test.exs test/aiur/prewarm/detect_test.exs`,
then `make all` before handoff. Manual: `aiur init` in a private repo with a valid
`GITHUB_TOKEN` builds the warm base; with an invalid token, the classified report
+ AI prompt appears.
