# nightly-release

Cuts one nightly per local date from a green commit. For each configured
package whose paths changed since that package's last nightly, it creates a
git tag, a GitHub prerelease, and the registry publish for the package's kind.
Any repo can use it as a GitHub Action.

## How a run decides

1. **Date.** The date is read in the config `timezone` (Intl applies DST). If
   the day tag `nightly-YYYYMMDD` exists, today is done and the run stops.
2. **Candidate.** The `--sha` input, or the head of `branch`. It must be on
   `branch`.
3. **Green.** For each workflow in `required_workflows`, the newest `push` run
   at that exact sha on `branch` must have `conclusion: success`. Scheduled and
   manual runs neither block nor decide. A run still in progress is polled for
   up to 10 minutes. Not green: stop, nothing written.
4. **Per package.** Skip if `nightly/<name>/<date>` exists (already done today)
   or if `git diff <last nightly/<name>/* tag> <sha> -- <paths>` is empty.
   Otherwise release it.
5. **Release.** Create the tag `nightly/<name>/<date>` at the sha, then a
   prerelease (never `latest`) whose notes list the commits under `paths` since
   the last nightly, then the kind action. A `dispatch` package starts its
   workflow on the tag, finds that run (a `workflow_dispatch` run on the tag at
   the sha, created after the dispatch) and waits up to 120 minutes for it; a
   run that does not succeed is a package failure. Then prune that package's
   nightly prereleases beyond `retain` (default 14); the tags stay as change
   baselines, and a prune error is only a warning.
6. **Finish.** If no package failed, create `nightly-YYYYMMDD`. A failed
   package has its prerelease and tag rolled back, the other packages still
   ship, the job is red, and the day tag is withheld so the next trigger
   retries only the failed package. The one exception: a dispatched run still
   in progress at the wait limit keeps its tag (the run may be checking it
   out), so delete that tag by hand to retry.

`--dry-run` stops after the plan and writes nothing. It still writes `act`,
`docker` and `sha` to `$GITHUB_OUTPUT` (also action outputs), so a read-only
plan job can gate a publishing job that holds the write scopes; see
`.github/workflows/nightly-release.yml`.

## Config

`.github/nightly-release.json` in the calling repo:

```json
{
  "timezone": "America/Los_Angeles",
  "branch": "main",
  "required_workflows": ["ci.yml"],
  "retain": 14,
  "packages": [
    {
      "name": "voice_converse",
      "kind": "git-tag",
      "paths": ["packages/elixir/voice_converse"],
      "version_file": "packages/elixir/voice_converse/mix.exs"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | Tag segment: `[a-z0-9][a-z0-9_.-]*`. |
| `kind` | `dispatch`: run `workflow` (with `inputs`) in this repo on the new tag. Use it for npm, because npm trusted publishing only accepts the workflow file registered with npm. `docker`: re-tag the existing `<image>:<sha>` as `:nightly` and `:<version>` (the image for the sha must already be pushed). `git-tag`: tag and prerelease only, for git dependencies such as Elixir packages. |
| `paths` | Paths whose change since the last nightly releases this package. |
| `version_file` | `mix.exs` or `package.json`; its first `version` is `{base}`. |
| `version` | Template, default `{base}-nightly.{date}`. Also `{sha7}`. |
| `prerelease` | `false` when the dispatched workflow owns its own release (Stream Deck's rolling `streamdeck-nightly`). |

Adding a package is one entry. A new kind is the only change that needs code
(`actions` in `nightly-release.mjs`).

## Using it from another repo

Pin the action to a full commit SHA of `aiur-team/aiur`. The caller owns the
triggers and permissions. Example for `aiur-team/khala`:

```yaml
name: nightly-release
on:
  schedule:
    - cron: "7,37 7-16 * * *"
  workflow_dispatch:
    inputs:
      dry_run: { type: boolean, default: true }
permissions:
  contents: read
concurrency:
  group: nightly-release
  cancel-in-progress: false
jobs:
  nightly:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      actions: write
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: aiur-team/aiur/.github/actions/nightly-release@<40-char sha>
        with:
          dry-run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run || 'false' }}
```

With a config such as:

```json
{
  "timezone": "America/Los_Angeles",
  "branch": "main",
  "required_workflows": ["ci.yml"],
  "packages": [
    {
      "name": "khala",
      "kind": "dispatch",
      "paths": ["packages/agent", "apps"],
      "version_file": "packages/agent/npm/package.json",
      "workflow": "release-npm.yml",
      "inputs": { "channel": "nightly" }
    }
  ]
}
```

Khala's `release-npm.yml` has only `stable` and `dry-run` channels today. It
needs a `nightly` channel (version from the dispatched tag, `npm publish --tag
nightly`) before this entry can publish.

Add `packages: write` and a `docker/login-action` step for a `docker` package.
A private repo must keep checkout's default `persist-credentials`, because the
script runs `git fetch` for tags.

## Tokens

The action uses the `token` input, which defaults to the job's `GITHUB_TOKEN`.
No other secret is needed: npm publishes through the dispatched workflow's OIDC
trusted publisher, and GHCR accepts `GITHUB_TOKEN`. A `GITHUB_TOKEN` can
dispatch `workflow_dispatch` workflows in its own repo only.

## Tests

```sh
node --test packages/nightly-release/test/lib.test.mjs
```

All decisions are in `lib.mjs` (pure). `nightly-release.mjs` holds only the
git, `gh` and `docker` calls.
