# PR checks

Only the aggregate `ci gate` check is required; it fails when any job the event selects did not succeed.

The approval check reads `reviewDecision` when the run starts; approval does not trigger another run, while the merge queue runs the full suite; add `ci:full` to run it on the PR first.

| Event | Jobs |
|-------|------|
| Pull request, not approved | `changes`, workflow security, pre-handoff, `lint`, affected tests, and the soak jobs when the PR changes tests. No Dialyzer or browser smoke. |
| Pull request, approved | The above, plus Dialyzer for `src/lib` changes and browser smoke for web changes; `merge_policy.full_ci_paths` or an unsafe test selection runs the full set |
| Pull request with `ci:full` or a `merge_policy.full_ci_labels` label | The full set, approved or not |
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


## Home page browser checks

The home page has no pixel comparison with the design reference. The operator
removed those tests ([#6061](https://github.com/aiur-team/aiur/issues/6061)).
Its browser specs test behaviour, including motion invariants under reduced motion.

Browser smoke runs on **nine shards**. Shard balancing uses the recorded CI
timings in `src/browser/scripts/browser-smoke-durations.mjs`, and
`scripts/check-browser-smoke-shards.mjs` keeps each shard under 75% of its budget.

The motion suite checks product behavior and deterministic browser helpers. It
does not compare numeric motion records with the design.

Gantt checks (`npm run test:build-home-gantt`) cover product layout invariants,
live updates and unknown-value captures.
