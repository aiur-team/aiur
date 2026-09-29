# U0 CE vendor source and overlay provenance

Eight oversized CE files in the 359-row owner map (rows 175, 184, 190, 204, 208, 216, 229 and 232) were bundled into Aiur by [PR #2015](https://github.com/aiur-team/aiur/pull/2015), merged as `8c00340dfa3b5eb141415565e243216b3eea4e59` on 2026-08-16. The PR says “Compound Engineering 3.19.0” and added `.claude/skills/compound-engineering.version`, but recorded no upstream commit SHA. The named [upstream 3.19.0 tag](https://github.com/EveryInc/compound-engineering-plugin/tree/1756c0b9f3cf94493f287ea29ae766ad668fb7cf) is `1756c0b9f3cf94493f287ea29ae766ad668fb7cf` (2026-07-08): its plugin manifest says `3.19.0`, but it has 29 skill directories rather than Aiur's 31, and none of the eight audited file blobs match at that tag. Two audited script paths do not exist there. A version string therefore does not identify Aiur's bundled source tree.

The exact reproducible source is upstream commit [`4aeaf6853074efe021409e880ad27958bf07bca6`](https://github.com/EveryInc/compound-engineering-plugin/tree/4aeaf6853074efe021409e880ad27958bf07bca6) (2026-07-18), whose plugin manifest still says `3.19.0`. All **eight audited oversized files** match that commit byte-for-byte. Its 31 skill names match Aiur's `compound-engineering.skills` manifest, and **254 of Aiur's 259 managed skill files** match byte-for-byte; the MIT license also matches. The five differences are three `ce-babysit-pr` files (`SKILL.md`, `references/watch-loop.md`, `scripts/pr-snapshot`) and two `ce-resolve-pr-feedback` files (`references/full-mode.md`, `scripts/reply-to-pr-thread`). The three babysit versions occur later in upstream history; the two feedback versions were not found as exact same-path blobs in fetched upstream history. All five entered Aiur in the bundling commit, so the current Aiur tree plus the public upstream commit fixes their exact bytes without relying on a private cache.

A local Claude plugin cache labeled `3.19.0` matches **257/259** Aiur managed files, differing only in the two feedback files. This supports, but does not prove, that the bundle was copied from a mutable cache snapshot and then adjusted. The cache is machine-local, unversioned by Git, and is not a suitable regeneration authority. The public upstream commit plus the [five-file overlay patch](ce-upstream-4ae-to-aiur-overlay.patch) is the reproducible authority for this research snapshot. The patch is research evidence (882 physical lines), so it must remain outside a future main branch with the universal 500-line gate.

## Reproduction from public sources

From the research checkout, use a fresh disposable upstream clone outside the Aiur checkout. The patch is relative to upstream `skills/`; it includes only the five differing managed paths.

```sh
scratch="$(mktemp -d "${HOME}/aiur-ce-repro.XXXXXX")"
git clone https://github.com/EveryInc/compound-engineering-plugin.git "$scratch/ce-upstream"
git -C "$scratch/ce-upstream" checkout 4aeaf6853074efe021409e880ad27958bf07bca6
git -C "$scratch/ce-upstream" apply --check "$PWD/docs/research/refactor-2026-09-26/synthesis/ce-upstream-4ae-to-aiur-overlay.patch"
git -C "$scratch/ce-upstream" apply "$PWD/docs/research/refactor-2026-09-26/synthesis/ce-upstream-4ae-to-aiur-overlay.patch"
while IFS= read -r skill; do diff -qr "$scratch/ce-upstream/skills/$skill" ".claude/skills/$skill"; done < .claude/skills/compound-engineering.skills
cmp "$scratch/ce-upstream/LICENSE" .claude/skills/compound-engineering.LICENSE
```

The exact patch checksum is `sha256:daf4509459b045a8ee8a77cde3d293cbf8178a0a71d4a72ce2f63893a1270420`. In a disposable upstream worktree, I generated that patch from the five Aiur files, restored the source, confirmed `git apply --check`, applied it, and compared all 259 managed files: **0 missing or mismatched**. The 31 skill names and license also matched. The patch retains whitespace already present in the source files so its reproduction stays byte-exact; `git diff --check` on this raw evidence patch reports those lines. This proves snapshot reproduction, not an implemented future update workflow.

## U0 action decision and remaining gate

The eight rows' **source-identity uncertainty is resolved**: start from exact upstream commit `4aeaf685...`, carry the five-file Aiur overlay, and preserve Claude/Codex workspace parity while splitting. Their **regeneration action remains gated**. `scripts/update-compound-engineering-skills` currently validates only the upstream version field and then replaces every managed skill directory; it neither pins the commit nor reapplies an overlay. Running it on the actual `3.19.0` tag would silently change the audited files and omit two skill directories. Before a CE split can close a row, choose a main-branch-compliant, reproducible overlay/source layout, make the updater enforce commit identity and apply the overlay, and test all 31 skill trees, Codex symlinks, `Aiur.AgentSkills` installation, skill-relative references and release workspace contents. Do not vendor the 882-line research patch into main as an exemption or claim that a source match is a completed decomposition.
