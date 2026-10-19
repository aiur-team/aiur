# PR checks

Only the aggregate `ci gate` check is required; it fails when any job the event selects did not succeed.

| Event | Jobs |
|-------|------|
| Pull request | `changes`, workflow security, `lint`, affected tests (or the full set with `ci:full`), and the soak jobs when the PR changes tests |
| Merge group | The full suite once: coverage, tests, Dialyzer, browser smoke, release smoke, analytics, Stream Deck. No soak. |

## Soak

A test that fails 2–3% of the time passes the merge group's single run and
lands on `main`. The soak runs the tests a pull request **adds or modifies**
many times, so the PR that introduces a flake is the one that fails.

Run counts depend on how many test files the pull request changes.

| Changed files | ExUnit (`soak changed tests`) | Playwright (`soak changed browser specs`) |
|---------------|-------------------------------|-------------------------------------------|
| Up to the full limit (10 ExUnit files, 3 specs) | 10 runs | `--repeat-each=5` |
| Above the full limit | 3 runs | `--repeat-each=2` |
| Above the cap (40 ExUnit files, 10 specs) | skipped, with a notice | skipped, with a notice |

- Each ExUnit run is a separate `mix test <files> --seed <s> --max-cases 8`
  invocation with a fresh seed. Separate invocations catch state that leaks
  between runs, such as global application env, leaked processes and shared IDs.
- Only specs that the browser smoke suite runs are soaked, with every registered smoke selection’s filters, config, workers and shards.
  Dormant full-matrix aliases are excluded.
- Each job stops starting new runs after 12 minutes and reports how many runs
  passed. An ExUnit invocation times out after 5 minutes; a browser invocation after
  the remainder of a 20-minute browser runtime bound. A timeout counts as a failure. An in-flight invocation may finish
  beyond the 12-minute launch budget; unstarted selections are reported.
- A failure prints the exact command to reproduce it, including the seed.


## Home band and mobile parity

PR browser smoke stays at **seven shards**, including PRs selecting full CI.
The routine pixel selection uses **390px**, datasets **live/offline**, both
**dark/light** themes and **gruvbox/aiur** palettes: eight band pixel cases and
eight unmasked composed mobile card/header cases.

Routine motion runs the ten
snap sequences at live/390px/dark/gruvbox. It preserves the scroll-curve regression.

The full check preserves all **104 band/mobile pixel cases** (seven band datasets,
three widths, both themes/palettes, plus twenty mobile composition cases) and
**32 band-motion cases**, including desktop normal/reduced motion, mobile snap,
grain and pulse. Routine CI, pull requests and merge groups never run the
full check, and no schedule runs it.

The full check runs only on demand: Actions → **home parity sign-off** (`workflow_dispatch`).

| Sign-off job | Covers |
|--------------|--------|
| band 1–4/4 | `npm run test:build-home-band-full` with `AIUR_HOME_PARITY_PART=1..4`. |
| motion 1–32/32 | Every spec that reads `AIUR_PARITY_FULL`, with the flag set: about 5,000 tests. |
| One job per other parity spec | Each `*parity*` browser spec, through its existing npm script. |

The sign-off is meant to run once, when the home-page tickets are done, and
again after their gaps are fixed. One run costs about 15–20 runner-hours.

`scripts/test-home-parity-signoff.mjs` fails when a parity spec has no sign-off
job. Every partition uses one browser worker, because dataset selection is
global to its fixture server.

A failed job's summary lists each failed cell: spec, dataset, width, theme,
palette and motion setting, with its artifact folder. The uploaded artifact
holds the cell's `-diff`, `-actual` and `-expected` screenshots, so each gap
can become a ticket.

Shard balancing uses recorded CI timings; until the
first routine run is measured, the previous full selections’ 303s parity and
280s motion measurements serve as conservative bounds, not routine timings.
