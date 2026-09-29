# Validate the repository you are changing

Aiur dispatches workers into many languages and build systems. Its bundled
skills do not make a target workspace an Elixir project.

1. Read the target repository's AGENTS.md, CONTRIBUTING instructions, package
   manifests, lockfiles and CI workflow before selecting validation commands.
   In a monorepo, identify the affected package and its runner configuration.
2. Run focused tests for changed behavior and directly affected callers. Use
   the repository's documented test command and installed package manager;
   for TypeScript, inspect package.json scripts and the selected runner's file
   filters rather than assuming npm, pnpm, Vitest, Jest, or a `test` script.
   Run the required typecheck, formatting and lint checks for that repository.
   Where practical, verify a new behavior test fails with the production
   change reverted in an isolated worktree, then passes when it is restored.
3. Search all relevant test roots for renamed identifiers, including colocated
   tests and sibling files outside a directory-targeted run. A large passing
   count does not prove those files ran. Follow local concurrency/resource caps.
4. Only Aiur's Elixir core uses the dev-loop's `mix aiur.affected_tests`,
   `mix test --max-cases 4`, ExUnit trace advice and `make ci` examples. The
   presence of an installed aiur-agent skill is not evidence those commands
   exist. A frontend package in the Aiur repository can use a different runner.
5. Run the target repository's required full gate at its prescribed stage.
   Report exact commands and results, including genuine environment blockers;
   do not claim unrun tests pass or broaden a focused pass into a full CI pass.

The prohibition on destructive `scripts/aiurdev --test` / `--test3` sandbox
resets is not a prohibition on focused repository tests. Keep that reset guard;
do not bypass it through a copied harness, another checkout, or another path.
