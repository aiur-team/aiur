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
- Only specs that the browser smoke suite runs are soaked, with the same
  `--config`.
- Each job stops starting new runs after 12 minutes and reports how many runs
  passed. One run times out after 5 minutes, which counts as a failure.
- A failure prints the exact command to reproduce it, including the seed.
