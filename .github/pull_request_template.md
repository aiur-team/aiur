Closes #<!-- issue number; use Fixes or Resolves if you prefer; list multiple as `Closes #43, #46` -->

#### Context

<!-- Why is this change needed? Length <= 240 chars -->

#### TL;DR

*<!-- A short description of what we are changing. Use simple language. Assume reader is not familiar with this code. Length <= 120 chars -->*

#### Summary

- <!-- Details of the changes in bullet points -->
- <!-- Keep them high level -->
- <!-- Each item <= 120 chars -->

#### Alternatives

- <!-- What alternatives have been considered? Why not? -->

#### Complexity routing

- Signal: <!-- `complexity:N`, or `untagged -> treated as complexity:3` -->
- Skills used: <!-- e.g. `ce-plan` -> `ce-work` -> `ce-code-review`; include model/provider path when relevant -->
- Rationale: <!-- Why this route fit this issue after inspection -->
- Adjustment: <!-- Followed the recommendation, moved up/down, or explain why no adjustment was needed -->

#### Docs

<!-- Keep one of the two lines below, delete the other, and delete every comment on the line you keep — `mix pr_body.check` rejects a body that still contains any `<!--`. Docs live in `website/docs-app/`: config keys in `reference/configuration.md`, commands and flags in `reference/cli.md`, user-facing surfaces in `guide/`, explanations in `concepts/`. Prefer editing an existing page over adding one — a wrong doc is worse than a missing one. -->

- [ ] Docs updated in this PR — name the pages <!-- required for: a new or changed config key, a CLI command or flag, an operator-set env var, a new user-facing surface (dashboard page, TUI view, Stream Deck mode, panel), or a change that makes an existing page wrong -->
- [ ] Docs not required <!-- internal refactor, bug fix restoring already-documented behavior, test-only change, or performance work with no interface change -->

#### Test Plan

- [ ] `make -C elixir all`
- [ ] <!-- Additional targeted checks (list below) -->
