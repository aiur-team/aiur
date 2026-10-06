---
design_task: DESIGN-R4
feature_id: MP-R4
owner: Kevin
status: open (awaiting explicit approval)
blocks: MP-R4-C1-T01..T02
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R4/plan.md
---

# DESIGN-R4 — Kevin: confirm that the hooks.aiur.dev relay stays a webhook-only tunnel, and approve the relay configuration surface

**MP-R4 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [ ] **No user-facing change is intended.** Everything below stays as it is:
  - the webhook route (`/api/v1/github/webhook`) and its behaviour;
  - the `webhooks.*` keys and `AIUR_GITHUB_WEBHOOK_SECRET`;
  - the per-repo delivery-mode output in the CLI;
  - the attention texts.
- [ ] **Your `hooks.aiur.dev` tunnel is unchanged.** It stays path-scoped to
  the webhook, with a catch-all 404. It will not carry mobile, dashboard or
  push traffic.
- [ ] **Relay configuration UX: none added.** Ingress (tunnel, domain) stays
  operator infrastructure outside Aiur. Configuration stays `webhooks.repos`
  plus the secret env var. Aiur does not start, manage or detect tunnels. If
  you want a guided setup (for example, an `aiur init` step that prints the
  tunnel ingress snippet), that is a Bucket 2 request: tick here and it is
  filed separately. [ ]

## 2. Decisions needing your input

1. Keep the `hooks.aiur.dev` tunnel purely for GitHub webhooks.
   [ ] yes (recommended)  [ ] no: explain ______
2. **Forwarded to DESIGN-N4 / MP-N4; answer there.** Self-hosted daemons cannot
   hold Apple or Google push credentials for a published app (plan § 4.3), so
   mobile push needs a publisher-operated push gateway or a self-built app.
   This gate records only that you have seen the constraint.
   [ ] seen

## 3. Copy to approve (docs only)

This is the § Cloudflare tunnel boundary addition to `website/docs-app/apis/github.md`:

> Any HTTPS ingress that forwards only `/api/v1/github/webhook` works —
> Cloudflare is one example. Whoever operates the ingress can see each
> delivery's metadata [and body — pending Phase C confirmation]. Without any
> ingress, polling remains the complete fallback.

- [ ] Approved, or edits: ______

## 4. States

No new screens. The existing webhook states (not configured; configured but
never delivered; delivering; silent past threshold) are unchanged.
