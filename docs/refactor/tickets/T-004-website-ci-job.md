# T-004: Website CI job (own workflow file)

**Phase:** 1
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:1` `complexity:1`

## Problem / context

`website/` has zero CI. Its only guards are manual commands the developer is
trusted to run before pushing (`website/AGENTS.md` lines 5–16: `npm run
typecheck`, `npm run assert` — the byte-identical 88-col golden snapshot —
and `npm run build`), and `website/AGENTS.md:16` states outright: "There is
no CI gate for the website, so these guards are the only safety net." The
feature inventory flags this exact gap: FI-SITE-028 notes the golden
snapshot assert is "not wired into CI, so a refactor that skips `npm run
assert` silently ships a changed frame." Phase 5 refactor tickets (T-055
through T-059) will modify `website/`, so this gate must exist first.

This ticket creates a NEW, self-contained workflow file
`.github/workflows/website.yml` that runs the three guards on every pull
request touching `website/**`. It does NOT touch `.github/workflows/ci.yml`
— T-001 owns that file. Note: bun is only the Netlify deploy's package
manager (`website/netlify.toml`, FI-SITE-032); `website/package-lock.json`
exists and is kept in sync with `package.json`, so CI uses `npm ci`.

## Scope (exact)

1. Create the file `.github/workflows/website.yml` with EXACTLY this
   content (byte-for-byte; do not reformat, reorder, or rename anything):

   ```yaml
   name: website

   on:
     pull_request:
       paths:
         - "website/**"
         - ".github/workflows/website.yml"

   jobs:
     guards:
       runs-on: ubuntu-latest
       defaults:
         run:
           working-directory: website
       steps:
         - name: Checkout
           uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
         - name: Set up Node
           uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e # v6.4.0
           with:
             node-version: "20"
             cache: npm
             cache-dependency-path: website/package-lock.json
         - name: Install deps
           run: npm ci
         - name: Typecheck
           run: npm run typecheck
         - name: Golden snapshot assert
           run: npm run assert
         - name: Build
           run: npm run build
   ```

   Rationale you do not revisit (decided; listed only so you don't
   "improve" them): the `actions/checkout` pin is copied verbatim from
   `.github/workflows/ci.yml:17` (repo convention: full commit SHA + ` #
   vX.Y.Z` comment); `actions/setup-node` v6.4.0 resolves to commit
   `48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e` (verified against
   `actions/setup-node` tags); Node 20 matches Netlify's `NODE_VERSION=20`
   (`website/netlify.toml`); the workflow lists its own path under `paths:`
   so the PR that adds it triggers a run and merges with a green check;
   guard order typecheck → assert → build matches `website/AGENTS.md:5-15`.

2. Verify the guards pass locally, mirroring CI exactly, from the repo
   root:

   ```
   cd website && npm ci && npm run typecheck && npm run assert && npm run build
   ```

   All four commands must exit 0. `npm run assert` must print its OK lines
   for all 6 checks. If any fails, your workspace is broken — do not
   "fix" website sources; comment the blocker on the issue.

3. Run the Agent gate (Verification section below) from `src/` to confirm
   the Elixir tree is untouched and green.

## Files

- Create: `.github/workflows/website.yml`
- Modify: None
- Test: None (the workflow file is itself the gate; its steps execute the
  existing `website/scripts/assert-sim.ts` suite — no new test files)

## Out of scope

- `.github/workflows/ci.yml` — owned by T-001; do not add a website job
  there, do not edit it for any reason.
- `.github/workflows/*` other than the one new file (T-005 owns the
  tripwire workflow).
- `website/package.json`, `website/package-lock.json`, `website/bun.lock`
  — no dependency or script changes.
- `website/netlify.toml` — the Netlify deploy path stays bun-managed.
- Any file under `website/src/`, `website/scripts/`, `website/public/` —
  especially no golden-snapshot regeneration (`scripts/gen-golden.ts` is
  deliberate-only).
- Push triggers, main-branch triggers, docs builds (VitePress arrives in
  T-055 and will extend this workflow in its own ticket), caching of
  `node_modules`, matrix builds, or any other workflow features.

## Inventory-IDs

- FI-SITE-028 — golden snapshot byte-identity (this ticket closes its
  "not wired into CI" gap)
- FI-SITE-029 — `npm run assert` invariant suite (now runs in CI)
- FI-SITE-031 — typecheck + build guards (now run in CI)
- FI-SITE-032 — Netlify deploy of aiur.team (context constraint: bun is
  Netlify-only; `package-lock.json` drives `npm ci`; deploy untouched)

## Characterization-tests

- `website/scripts/assert-sim.ts` (invoked by `npm run assert`) — the
  existing 6-check invariant suite including the byte-identical golden
  snapshot (`website/scripts/dashboard-golden.json`). This ticket does not
  create new tests; it wires the existing suite into CI so it runs on
  every `website/**` PR.

## Acceptance criteria

- `.github/workflows/website.yml` exists and is under 60 lines
  (norm: each new file <= 200 lines).
- `grep -F 'working-directory: website' .github/workflows/website.yml` matches.
- `grep -F '"website/**"' .github/workflows/website.yml` matches under `paths:`.
- `grep -F 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2' .github/workflows/website.yml` matches.
- `grep -F 'actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e # v6.4.0' .github/workflows/website.yml` matches.
- `grep -F 'node-version: "20"' .github/workflows/website.yml` matches.
- `grep -F 'run: npm ci' .github/workflows/website.yml` matches.
- `grep -F 'run: npm run typecheck'`, `grep -F 'run: npm run assert'`, and
  `grep -F 'run: npm run build'` each match, appearing in that order in
  the file.
- Every `uses:` line in the new file is SHA-pinned with a trailing version
  comment: `grep -E 'uses: .+@[0-9a-f]{40} # v[0-9]' .github/workflows/website.yml`
  matches the same number of lines as `grep -c 'uses:'`.
- `git diff --name-only v2...HEAD` outputs exactly one path:
  `.github/workflows/website.yml` (in particular, `.github/workflows/ci.yml`
  shows no diff).
- `cd website && npm ci && npm run typecheck && npm run assert && npm run build`
  all exit 0 locally.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
Website gate (this ticket touches the website CI surface; run from repo
root):
```
cd website && npm run typecheck && npm run build && npm run assert
```

### At-merge (reviewer)

- The PR shows a new required-style check `website / guards` (triggered
  because the workflow lists its own path) and it is green — all four
  steps (Install deps, Typecheck, Golden snapshot assert, Build) passed.
- Check: `cd website && npm run assert` prints all-OK and exits 0
  (FI-SITE-029's named probe).
- Confirm `git diff v2...<branch> -- .github/workflows/ci.yml` is empty
  (T-001's file untouched).
- Confirm no changes under `website/` itself:
  `git diff --name-only v2...<branch> -- website/` is empty.
- No label applications or TUI checks apply to this ticket.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
