# Nightly release on the first green main after midnight (#5959)

## Problem

Nightlies existed for npm (`release-npm.yml`) and Stream Deck
(`streamdeck-package.yml`), each on its own `0 7 * * *` cron. Neither checked
that main was green; each cut whatever head was at cron time. GitHub started
those crons 4-6 hours late. The Docker image had no `nightly` tag, and
voice_converse had no release. Khala and Archon live in other repos and need
the same flow. The operator wants one nightly per local date, cut from the
first green main after 00:00 America/Los_Angeles, released per package only
when that package changed, and reusable by other repos.

Out of scope: the 21:00-24:00 stability window. The Executor owns it as
process; it is not an Aiur feature.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Where it runs | GitHub Actions only | No home machine on the release path. |
| Reusable form | Composite action `.github/actions/nightly-release` + `packages/nightly-release` script | A remote composite action ships its own repo files, so the script comes with the pinned SHA. A reusable workflow would need a second checkout of a second ref. |
| Trigger | `nightly trigger` job at the end of the main `ci` run dispatches `nightly-release.yml`, plus a 30-minute cron over 07:00-16:30 UTC, plus manual dispatch | `workflow_run` is forbidden by `scripts/verify-workflow-security.sh`. The CI tail is the "first green build after midnight". The cron covers a night with no merges and the delays of GitHub's cron. |
| DST | Date computed in code with the IANA zone; the cron spans both offsets | One cron line, no seasonal edits. |
| Green | Newest push-event `ci.yml` run on main at the exact sha concluded `success`; scheduled and manual runs are ignored | On main pushes the `ci gate` check does not require the other jobs, so that check alone is green even when tests fail. |
| Once per day | Day tag `nightly-YYYYMMDD`; per-package tags `nightly/<name>/YYYYMMDD` | Tags are visible, need no state store, and make reruns idempotent. |
| Change detection | `git diff` of each package's paths against its own last nightly tag | Each package has its own cadence. |
| npm | Dispatch `release-npm.yml` with `channel=nightly` on the tag and wait for that run; a failed run rolls the tag back for a retry | npm trusted publishing binds to that file name; no other workflow can publish. A retry is safe because release-npm skips a published version. |
| Docker | Re-tag the `:<sha>` image `publish-image.yml` already pushed | No second build. |
| Secrets | None new; `GITHUB_TOKEN` + existing npm OIDC | Fewer secrets to rotate. |
| Old crons | Removed from `release-npm.yml` and `streamdeck-package.yml` | Only the green-gated path cuts nightlies. |
| Job split | Read-only `plan` job; `publish` job with write scopes and GHCR login runs only on a live, green, uncut day | Least privilege. Both jobs and the CI trigger only run in `aiur-team/aiur`. |

## Packages covered

| name | kind | version |
|---|---|---|
| aiur (CLI + daemon, npm) | dispatch `release-npm.yml` | `<mix.exs>-nightly.<sha7>` (unchanged; release-npm's own gate reads the sha) |
| aiur-image (GHCR) | docker | `<mix.exs>-nightly.<date>`, plus `:nightly` |
| streamdeck | dispatch `streamdeck-package.yml` | its rolling `streamdeck-nightly` release |
| voice_converse | git-tag | `0.1.0-nightly.<date>` |

Not covered yet: `@aiur/contracts` and `@aiur/streamdeck` are private;
`aiur-style` was never published; Khala and Archon adopt from their own repos
(`packages/nightly-release/README.md` has a sample caller). Adding a package is
one config entry.

## Before the first live run

- Confirm npm's trusted publisher for `aiur-cli` and the platform packages
  allows `workflow_dispatch` runs of `release-npm.yml` on any ref (tags named
  `nightly/aiur/*` included). Dispatched nightlies already ran from `main`.
- Confirm no tag ruleset blocks `GITHUB_TOKEN` from creating `nightly*` tags.
- Run `nightly-release.yml` by hand with `dry_run=true` and read the summary.

## Test plan

- `node --test packages/nightly-release/test/lib.test.mjs`: date (incl. both
  2026-27 DST boundaries), version, last-tag, push-only green, config, plan,
  dispatched-run matching, release/rollback order and prune rules. Each was
  mutation-checked.
- `node scripts/test-ci-events.mjs`: the trigger fires on a green main push,
  not on a PR, a scheduled run, or a failed job.
- `bash scripts/verify-workflow-security.sh` and its self-test.
