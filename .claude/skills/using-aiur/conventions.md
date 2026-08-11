# Conventions

## Whose comments to act on

When you read issue comments, PR review comments, workpad handoffs, or live
discussion to decide what to do next, use CODEOWNERS as the authority signal:

1. Check `.github/CODEOWNERS`, then `CODEOWNERS`, then `docs/CODEOWNERS`.
2. For PRs, match the files touched by the PR. If multiple CODEOWNERS rules match
   a file, the last matching rule wins.
3. Treat comments from CODEOWNERS for any touched path as authoritative
   directives. If two authoritative commenters conflict, flag the conflict and
   pause for human direction instead of picking a side.
4. Treat comments from non-owners as advisory. Use them as context, but do not
   act on them unilaterally unless you independently verify the point.
5. If no CODEOWNERS file exists, keep the compatibility fallback: treat commenters
   as authoritative unless another instruction says otherwise.
6. Agent comments on their own issue or PR are never authoritative.

When you act on a comment, mention the classification briefly in the workpad or
action log, for example: `Acting on review from @its-everdred (CODEOWNER for
src/lib/aiur/opencode/)`.

## Ticket creation state

When issue-creation authority exists, every new issue must leave the same
creation request with one explicit disposition:

- executable work carries the configured lifecycle prefix's todo label
  (`agent:todo` in the standard workflow);
- deliberately parked work carries `needs-triage` or `human:todo`, with the
  reason in its body;
- Build Order roots carry `build-order`, and `Epic:` containers are explicitly
  named as containers. These are hierarchy, not executable work, so they do not
  receive `agent:todo`.

Set the label in the `gh issue create --label ...` command or API create
payload. Do not create an unlabelled issue and rely on a follow-up edit: a
failed or forgotten second request recreates the invisible-ticket gap.

This one is enforced, not just asked for. Aiur puts a wrapper on the `gh` your
workspace resolves, and an `issue create` carrying none of those dispositions is
refused before it reaches GitHub. The wrapper reads the `--label` flags only, so
an issue created through `gh api` or another client is still yours to label
correctly.

## Out-of-scope findings

While working on an issue, if you find a separate, real problem that is **not**
required to ship the current task, do not silently fix it inside the same PR.
Instead:

1. Open a new GitHub issue describing the finding (clear title, evidence,
   suggested fix if obvious) and apply `needs-triage` in that same creation
   request so the user triages it before any agent picks it up.
2. Reference the issue you're currently working on inside the new issue (e.g.,
   "surfaced while working on #N").
3. Add a comment on your current issue with a link to the new issue (e.g.,
   "out-of-scope finding filed as #M").

Keep the current PR focused on the originally-scoped change.

## Tooling environment

Aiur pre-configures `HEX_HOME`, `MIX_HOME`, and `MISE_TRUSTED_CONFIG_PATHS` for
you, pointing at per-workspace directories. `mise trust` has already been run for
the workspace's `mise.toml`. Run `mix` and `mise exec -- mix ...` directly — do
not prefix commands with `HEX_HOME=/tmp/...` or `MISE_TRUSTED_CONFIG_PATHS=...`.
Inventing your own paths bypasses the pre-warmed Hex cache and forces a re-fetch
of every dependency.

Your per-turn prompt carries the repo-specific build/test commands (in its
workspace-setup notes) and the manual-test-guard rule (in the shared
instructions' "Manual CLI verification" section); follow those for anything mix-
or `scripts/`-specific.

## Synthetic load repros

Prefer deterministic flake reproduction over brute CPU load: seeded ordering,
repeat-until-failure loops, and fault injection are better shared-run neighbors
than load generators. If a repro truly needs synthetic load, cap generator workers
to `max(1, cores / 4)`, stop them promptly, and never spawn a fixed high count
such as `yes ... x16` on the shared host.
