# MP-R4 partial acceptance evidence — 2026-10-29

Refs [#3449](https://github.com/aiur-team/aiur/issues/3449).
This report records the documentation audit and automated checks against main
at `747e862971c29f28eec311fb6cdb52154f47b092`.
Live daemon restart, loaded-build proof and rendered CLI/TUI evidence remain
unrun. This is not a complete end-to-end acceptance pass.

No runtime code or tests are changed by this report.

## Contract and merged member

The original plan is absent from current main. Its acceptance criteria were
retrieved through the GitHub contents API at research revision
`6732f5f9f448b1857a9643993849635f85321e19`:

- `docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R4/plan.md`, §7.
- The sibling `tickets/MP-R4-C1-T01.md`, including its verification section.

Member [#3448](https://github.com/aiur-team/aiur/issues/3448) shipped in
[PR #7065](https://github.com/aiur-team/aiur/pull/7065), merged at
2026-10-29 13:37:02 UTC as
`2bbcaf4715f339cf2f94cf12336e1d4fc1da4b83`.
`git merge-base --is-ancestor` confirmed that merge is in the audit baseline.
Its diff touches only `website/docs-app/apis/github-auth.md` and
`website/docs-app/reference/optional-optimizations.md`; its `src` diff is empty.

## Acceptance matrix

The historical criteria need the following qualifications on current main.

| Criterion | Evidence and result |
| --- | --- |
| 1. Ingress is optional and vendor-neutral; operator visibility is named | Pass, documentation audit: `apis/github-auth.md` § Cloudflare tunnel boundary names any HTTPS ingress, polling as complete fallback, and TLS-terminating operator access to headers/body. It distinguishes HMAC forgery protection from confidentiality. `reference/optional-optimizations.md` repeats the trust requirement. |
| 2. Route census guards the webhook authenticator | Existing census passes. The old wording naming only dashboard, supervisor and webhook auth predates client-token/session auth and public health probes. Current census explicitly audits these additional surfaces; this is not proof of the obsolete literal allowlist. |
| 3. No change to `src/lib` | Pass for the member's complete merge diff and this evidence-only change. |
| 4. MP-N4 and MP-Q2 context link to plan §4 | Unproven on current main: MP-R4 plan and context file are absent; the current MP-N4 plan is a later partial refresh without the link. Deferred coordinator finding DF-015. |

The retained Cloudflare heading and legacy `apis/github.md` anchor resolve to
`apis/github-auth.md#cloudflare-tunnel-boundary`. The hostname example,
webhook endpoint, secret name, catch-all 404 and firewall guidance remain.
The old 760-line API page was split before the member landed: #7065 leaves
`apis/github.md` at 139 lines and changes `github-auth.md` from 194 to 196.

The original TLS-visibility reasoning and primary-source links are recorded
in the member contract and #7065; this audit checks the shipped copy against
that contract and makes no new claim about a live tunnel's configuration.
There is no claimed quota, latency or cost saving.

## Automated evidence

Commands below run against the baseline above, using existing tests.
There are no new tests requiring a production-hunk revert check.

From `src/`:

```sh
mise exec -- mix test --max-cases 4 \
  test/aiur_web/route_auth_census_test.exs \
  test/aiur/webhooks/consumer_equivalence_test.exs
```

Result: 11 tests, zero failures. The three census tests check route
reachability/auth, socket inventory and rejection without proof. The eight
consumer tests run the same contract against polling and webhook sources,
including the absence of a transport marker. This is automated contract
coverage, not an observation of the live daemon or ingress.

Documentation build/spec results are recorded in the accompanying PR's
`Local tests` evidence. Those checks validate static documentation and its
existing guards; they do not exercise a live GitHub delivery.

## Remaining post-deploy checks

These exact checks require the Executor repository root and were not run in
this issue workspace. No restart of the shared daemon was attempted.
Record the main SHA, date, command output and capture locations when running.

1. From the Executor repo root on current main, run `scripts/aiurdev restart`;
   confirm the loaded daemon's build stamp matches that checkout's main SHA
   and record `scripts/aiurdev status` output. Operator: Executor.
2. Follow `docs/manual-testing.md` from the Executor repo root to launch
   `scripts/aiurdev --test --force --allow-remote`; drive its printed tmux
   socket/session, open an agent chat with Enter, send a unique message via
   the TUI input, and capture the rendered reply and command/tool rows with
   `tmux capture-pane`. Operator: Executor; never run the reset flags from
   an issue workspace.
3. Open the built docs at `/apis/github-auth#cloudflare-tunnel-boundary`,
   `/apis/github#cloudflare-tunnel-boundary` and
   `/reference/optional-optimizations`; follow the legacy link and capture
   the optional ingress, polling fallback, TLS visibility, HMAC distinction,
   path-only routing and catch-all guidance. Operator: Executor browser.

## Findings and disposition

No P0/P1 defect was found in the shipped documentation or automated contracts.
DF-015 records the missing research handoff links in
`docs/build-order/deferred-findings.md`.
The evolved route census is described explicitly rather than presented as
satisfying an outdated literal route inventory.

Keep #3449 open until the remaining live checks have dated evidence and the
coordinator resolves or explicitly supersedes the research handoff criterion.
The report PR uses `Refs #3449`, without a closing keyword.
