---
ticket_id: MP-R4-C1-T01
feature_id: MP-R4
chunk_id: MP-R4-C1
bucket: 1-refactor
title: Docs — webhook ingress is replaceable and optional; what the ingress operator can see
status: blocked
blocked_by: [DESIGN-R4, "U8 DOCS size owner for website/docs-app/apis/github.md (net growth ≤ 2 lines, or after its split)"]
prior_units: [U5, U8]
prior_boundaries: ["ING #9", "GHC #5"]
prior_features: [integrations-25, config-12]
prior_findings: []
size_owner: DOCS (website/docs-app/apis/github.md, 760 lines at base)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R4-C1-T01 — Docs: the webhook ingress is replaceable and optional, and what its operator can see

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R4 / C1.
- **User value:** an operator knows three things:
  - any HTTPS ingress that forwards only the webhook path works, and
    Cloudflare / `hooks.aiur.dev` is one example;
  - no ingress at all is a complete setup, because polling covers it;
  - whoever operates the ingress can read every delivery.
- **Deliverable:** two small doc edits. There is no code change, and
  `git diff -- src` is empty.
- **Non-goals:**
  - a relay abstraction or a push design (that is MP-N4);
  - renaming the `## Cloudflare tunnel boundary` heading. Its anchor
    `#cloudflare-tunnel-boundary` is linked from
    `optional-optimizations.md:77`, and the heading text is cited in
    `AGENTS.md:252` and `.claude/skills/aiur-meta/SKILL.md:82`.

## Dependencies and blockers

- **Blocked by:**
  - DESIGN-R4 approval: §1, §2.1 and the §3 copy. The bracketed "[and body —
    pending Phase C confirmation]" in §3 is now resolved; see CR-R4-1.
  - The U8 `DOCS` size owner. `apis/github.md` is 760 lines, above the
    500-line gate. This ticket keeps its net growth to 2 lines. If the owner
    forbids any growth before the split, it lands after the split, at the new
    path for this section.
- **Cites:** MP-R3-C1-T01. The route census proves that `:github_webhook` is the
  only non-dashboard, non-supervisor authenticator (plan acceptance item 2). No
  separate R4 test is written.
- **May run concurrently with:** MP-R3-C2-T01. It edits a different section of
  `optional-optimizations.md` (§ Tailscale / § Dashboard authentication, versus
  § Webhook ingress here).

## Verified starting point (base `45a290e3`)

- `website/docs-app/apis/github.md` (760 lines):
  - `## Optional webhook` is at `:702`.
  - `## Cloudflare tunnel boundary` is at `:742-760`, with:
    - the sentence "Cloudflare is transport for the GitHub webhook, not an API
      Aiur calls." (`:744`);
    - a 4-row requirement table (`:746-751`);
    - a 2-row lock table (`:755-758`);
    - the catch-all warning (`:760`).
- `website/docs-app/reference/optional-optimizations.md`
  § Webhook ingress and the Cloudflare tunnel (`:48-81`). Step 4 (`:79`)
  already says `hooks.aiur.dev` "is one operator's choice, not a requirement".
  Line `:81` already says polling is the default fallback.
- **Strings asserted by `website/tests/gui-docs.spec.ts:239-245`** must survive:
  - `` `POST /api/v1/github/webhook` ``
  - `` `AIUR_GITHUB_WEBHOOK_SECRET` ``
  - `` `hooks.aiur.dev` ``
  - ``catch-all `404` ``
  - `No inbound firewall rule`
- **Code facts the copy restates** (no change):
  - The route is first in the router under `:github_webhook`
    (`src/lib/aiur_web/router.ex:69-75`).
  - The HMAC check is in `AiurWeb.GithubWebhook.Auth`. The secret is read per
    request (`auth.ex:26,71-79`).
  - `src/lib/aiur_web` handles no `X-Forwarded-*` or `CF-Connecting-IP`
    header (baseline grep).
- **RQ2 (equivalence suite) answered.**
  `src/test/aiur/webhooks/consumer_equivalence_test.exs` runs four `mode_test`
  bodies (`:16`, `:25`, `:35`, `:44`) against both
  `EventSource.Polling` and `EventSource.Webhook`, through
  `src/test/support/webhook_mode_contract.exs`. Test `:35`, "the consumer is
  handed no transport marker to branch on", is the guard MP-R2 must keep
  running when it moves the bus. That is an input to MP-R2, not work here.

### RQ1 — does the Cloudflare ingress see delivery bodies? Answered: yes

- Cloudflare's edge-certificate docs say: "Edge certificates are the SSL/TLS
  certificates that Cloudflare presents to visitors connecting to your domain …
  These certificates secure the encrypted connection between your visitors and
  Cloudflare."
  Source: https://developers.cloudflare.com/ssl/edge-certificates/, accessed
  2026-10-06 (living docs, no version).
- The tunnel docs say "cloudflared initiates an outbound connection … from the
  origin to the Cloudflare global network".
  Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/,
  accessed 2026-10-06.
- **Conclusion:** GitHub's TLS session ends at Cloudflare's edge. The proxied
  request then travels to `cloudflared` over a separate connection. Cloudflare
  therefore handles each delivery's headers and body in plaintext at the edge.
  That conclusion follows from where TLS terminates. Neither page states it in
  one sentence, so the copy says "can read", not "logs".
- The HMAC signature stops an ingress operator from **forging** a delivery. It
  does not stop the operator from **reading** one.

## Chosen design

1. **`apis/github.md` § Cloudflare tunnel boundary.** Net change: +2 lines.
   - Replace `:744` with one sentence: "Cloudflare is one example of webhook
     ingress — any HTTPS ingress that forwards only `/api/v1/github/webhook`
     works, and none is required: polling is the complete fallback. It is
     transport, not an API Aiur calls."
   - Add one row to the lock table (`:755-758`):
     `| What a lock does not hide | The ingress operator terminates TLS, so it can read each delivery's headers and body; the signature stops forgery, not reading. |`
   - Add one row to the requirement table (`:746-751`):
     `| Other ingress | Any reverse proxy or tunnel that forwards only this path, with TLS, works the same; Aiur reads no proxy headers. |`
   - The heading, anchor, `hooks.aiur.dev` mention, catch-all sentence and
     firewall row are unchanged.
2. **`optional-optimizations.md` § Webhook ingress.** Net change: one sentence
   appended to `:81`: "Cloudflare is one ingress among many; whichever you use
   can read webhook deliveries, so treat it as trusted transport." Step 4
   already covers the hostname.
3. The final wording follows the DESIGN-R4 §3 approval, adjusted for the RQ1
   answer (CR-R4-1).

## Implementation steps

1. Edit the two pages as above.
2. Confirm that the line count of `apis/github.md` grew by at most 2
   (`wc -l`). State the count in the PR body for the U8 size owner.
3. Run the docs checks below.

## Non-happy paths

- **The owner answers DESIGN-R4 §2.1 "no"** (wants the tunnel used beyond
  webhooks). Stop. That contradicts plan § 3 option C and needs a new plan. Do
  not edit docs to suggest a wider tunnel.
- **The U8 split moved the section.** Apply the same edits at the new path, and
  keep the `#cloudflare-tunnel-boundary` anchor working (redirect or same
  heading).

## Compatibility and rollout

n/a — docs only. Rollback means reverting the commit. The anchor is preserved,
so existing links keep working.

## Verification

```bash
env -C <worktree>/website/docs-app bun run build
env -C <worktree>/website npx playwright test --project=brand tests/gui-docs.spec.ts
git -C <worktree> diff --stat -- src     # must be empty
```

Expected:

- the build succeeds with no dead-link error for `#cloudflare-tunnel-boundary`;
- `gui-docs.spec.ts:239-245` still passes.

There is no mutation check: no production hunk exists. Reviewers check every
sentence against the evidence above (AGENTS.md: review-enforced docs).

## Completion and handoff

- [ ] Both edits are applied with the approved copy.
- [ ] `apis/github.md` net growth is ≤ 2 lines, recorded in the PR.
- [ ] The anchor and the asserted strings are unchanged.
- **Docs pages:** this ticket is the docs change.
- **Dependents:** MP-N4 cites plan § 4, the fact sheet for MP-Q2. The coordinator
  links it (MP-R4-C2 has no implementation ticket). When MP-N4 lands a push
  page, MP-N4 adds the cross-link "push is separate from webhook ingress" to
  this section.
