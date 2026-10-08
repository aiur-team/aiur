---
design_task: DESIGN-R4
feature_id: MP-R4
owner: Kevin
status: approved by the Executor 2026-10-08 per EXECUTOR-APPROVALS.md (Kevin may revise)
blocks: [MP-R4-C1-T01]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R4 (waived entries excluded). Earlier wording: MP-R4-C1-T01..T02"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R4/plan.md
---

Executor decisions recorded in [EXECUTOR-APPROVALS.md](EXECUTOR-APPROVALS.md) (2026-10-08).

# DESIGN-R4 — Kevin: confirm that the hooks.aiur.dev relay stays a webhook-only tunnel, and approve the relay configuration surface

**MP-R4 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [x] (Executor, 2026-10-08) **No user-facing change is intended.** Everything below stays as it is:
  - the webhook route (`/api/v1/github/webhook`) and its behaviour;
  - the `webhooks.*` keys and `AIUR_GITHUB_WEBHOOK_SECRET`;
  - the per-repo delivery-mode output in the CLI;
  - the attention texts.
- [x] (Executor, 2026-10-08) **Your `hooks.aiur.dev` tunnel is unchanged.** It stays path-scoped to
  the webhook, with a catch-all 404. It will not carry mobile, dashboard or
  push traffic.
- [x] (Executor, 2026-10-08) **Relay configuration UX: none added.** Ingress (tunnel, domain) stays
  operator infrastructure outside Aiur. Configuration stays `webhooks.repos`
  plus the secret env var. Aiur does not start, manage or detect tunnels. If
  you want a guided setup (for example, an `aiur init` step that prints the
  tunnel ingress snippet), that is a Bucket 2 request: tick here and it is
  filed separately. [ ] (not requested; Executor, 2026-10-08)

## 2. Decisions needing your input

1. Keep the `hooks.aiur.dev` tunnel purely for GitHub webhooks.
   [x] yes (recommended) (Executor, 2026-10-08)  [ ] no: explain ______
2. **Forwarded to [DESIGN-N4 D-8](DESIGN-N4.md#3-decisions-that-need-kevin)
   (OQ-N4-1, publisher and default relay operator); answer there.** Self-hosted
   daemons cannot hold Apple or Google push credentials for a published app
   (plan § 4.3), so mobile push needs a publisher-operated push relay or a
   self-built app. DESIGN-N4 D-8 lists the options (organisation accounts and a
   hosted relay; self-built apps only; personal accounts) and recommends
   organisation accounts with a hosted relay. This gate records only that you
   have seen the constraint; that relay never uses `hooks.aiur.dev` (item 1).
   [x] seen (Executor, 2026-10-08)

## 3. Copy to approve (docs only)

This is the § Cloudflare tunnel boundary addition to `website/docs-app/apis/github.md`:

> Any HTTPS ingress that forwards only `/api/v1/github/webhook` works —
> Cloudflare is one example. Whoever operates the ingress can see each
> delivery's metadata and body; the webhook signature prevents forgery, not
> reading. Without any ingress, polling remains the complete fallback.

(Phase D, CR-R4-1: Phase C confirmed "body too" — TLS terminates at the ingress edge;
Cloudflare edge certificates "secure the encrypted connection between your visitors and
Cloudflare", https://developers.cloudflare.com/ssl/edge-certificates/, accessed 2026-10-06.)

- [x] (Executor, 2026-10-08) Approved as written.

## 4. States

No new screens. The existing webhook states (not configured; configured but
never delivered; delivering; silent past threshold) are unchanged.

## 5. Acceptance

The gate is complete when every box in §§ 1–3 carries your approval (item 2 needs
only "seen"; its answer is recorded in DESIGN-N4 D-8), and you record "DESIGN-R4
approved" with the date in this file.
