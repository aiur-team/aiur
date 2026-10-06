---
ticket_id: MP-R3-C2-T01
feature_id: MP-R3
chunk_id: MP-R3-C2
bucket: 1-refactor
title: Docs — reachability is not authorization; the dashboard is plain HTTP
status: blocked
blocked_by: [DESIGN-R3]
prior_units: [U8]
prior_boundaries: ["WEB #34", "CFG #2"]
prior_features: []
prior_findings: ["nonelixir-shell-27 (closed by #2995)"]
size_owner: n/a (optional-optimizations.md is 174 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R3-C2-T01 — Docs: reachability is not authorization; the dashboard is plain HTTP

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R3 / C2.
- **User value:** an operator reading the docs cannot conclude that Tailscale,
  or its absence, controls who may use the dashboard. The operator also learns
  three facts before trying a phone or a LAN bind:
  - Aiur serves plain HTTP;
  - Basic Auth over a non-tailnet network travels in cleartext;
  - the browser microphone needs HTTPS beyond loopback.
- **Deliverable:** edits to `website/docs-app/reference/optional-optimizations.md`.
  It also adds a one-line banner on `docs/voice-mode/spec.md`, but only if
  DESIGN-R3 §2.2 chooses the banner.
- **Non-goals:**
  - recommending a TLS solution: `tailscale cert`, a pinned self-signed
    certificate and a reverse proxy are all MP-N2 / DESIGN-N2 §transport
    choices (RC-15);
  - any code change;
  - a new page.

## Dependencies and blockers

- **Blocked by:** DESIGN-R3. The owner must approve:
  - the § Tailscale copy (DESIGN-R3 §3);
  - the "warning only" choice (§2.1);
  - the banner choice (§2.2);
  - the § Transport copy below. DESIGN-R3 does not yet contain that copy; see
    `CONTRACT-REQUESTS.md` CR-R3-1.
- **May run concurrently with:** MP-R3-C1-T01 (no shared files) and
  MP-R4-C1-T01. MP-R4-C1-T01 also edits `optional-optimizations.md`, but only
  § Webhook ingress (lines 48-81), so the two edits do not overlap. Merge order
  does not matter.
- **Feeds:** RQ-TRANSPORT (MP-N2). This ticket documents today's facts only.

## Verified starting point (base `45a290e3`)

`website/docs-app/reference/optional-optimizations.md` is 174 lines:

- § Tailscale (`:83-102`) says there is no auto-detection and that you set
  `server.host` to the tailnet IP. It does **not** say that Tailscale is not
  the authorization boundary.
- § Dashboard authentication (`:104-125`) says "Beyond loopback the listener
  refuses to start at all" (`:112`, `:116`). In code that means **only the
  HTTP child** returns `:ignore` (`src/lib/aiur/http_server.ex:55-56`,
  `:167-202`); the daemon and its agents keep running. The page does not say
  so.
- The page says nothing about transport (HTTP versus HTTPS).

Facts the new copy states, with evidence:

| Fact | Evidence |
| --- | --- |
| Aiur serves plain HTTP and never terminates TLS. | `http_server.ex:64` (`http:` only), `:147` (`"http://…"`); guarded by MP-R3-C1-T01 |
| Every route needs dashboard credentials, the supervisor token or a webhook signature, whatever the bind. | `router.ex:9-26`, `:69-199`; `financial_data_access.ex:50-86`; guarded by MP-R3-C1-T01 |
| The dashboard disables the microphone on an insecure origin. | `src/priv/static/conversation-voice-controller.js:18-19`: "Microphone access requires HTTPS or localhost. This dashboard origin is not secure." |
| Browsers allow `getUserMedia` only in secure contexts. | MDN, `MediaDevices.getUserMedia()`: "The getUserMedia() method is only available in secure contexts." https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia (accessed 2026-10-06; living document, no version) |
| A non-loopback bind without credentials disables only the listener. | `http_server.ex:55-56`, `:191-200` (the log line "re-run with --host 127.0.0.1") |

`docs/voice-mode/spec.md:3,6` reads "Status: Draft … Primary access: Aiur
dashboard on desktop or mobile over Tailscale".

`website/tests/gui-docs.spec.ts` asserts nothing about this page (no match for
`optional-optimizations` or `Tailscale`), so no test string constrains the edit.

## Chosen design

Edit the existing page; do not add one (AGENTS.md: prefer editing an existing
page).

1. **§ Tailscale → new "### What it does not do" subsection.** Use the DESIGN-R3
   §3 copy as approved:

   > Tailscale decides who can *reach* the dashboard and encrypts the path. It
   > never decides who is *allowed in*: every route still requires dashboard
   > credentials, the supervisor token, or a webhook signature, whatever address
   > the dashboard binds. Beyond loopback, without a tailnet, Basic Auth crosses
   > the network in cleartext.

2. **New "### Transport" subsection under § Dashboard authentication** (copy
   pending CR-R3-1):

   > Aiur serves the dashboard over plain HTTP and never terminates TLS. Off the
   > machine, encryption is the network's job — a tailnet encrypts the path; a
   > LAN does not. Browsers allow the microphone only on HTTPS or `localhost`, so
   > dashboard dictation is disabled on a plain-HTTP address beyond loopback.

   It names no HTTPS recipe; that is DESIGN-N2 §transport. When MP-N2 lands its
   transport choice, MP-N2's docs ticket adds a link here (plan § 9).

3. **§ Dashboard authentication, "The symptom" (`:112`) and the `dashboard_writable`
   paragraph (`:116`):** replace "refuses to start (at all)" with "the dashboard
   listener is disabled; agents keep running". This makes the page match
   `http_server.ex:55-56`.

4. **Conditional (DESIGN-R3 §2.2 = banner):** insert after
   `docs/voice-mode/spec.md:3`:
   `**Note (2026-10, MP-R3):** Tailscale is one supported network, not a requirement; see website/docs-app/reference/optional-optimizations.md.`
   Skip this step if the owner chose "leave untouched".

## Implementation steps

1. Apply edits 1–3 to `website/docs-app/reference/optional-optimizations.md`.
   The net growth is about 12 lines, and the page stays under 200 lines.
2. Apply edit 4 only if DESIGN-R3 §2.2 says so.
3. Build the docs site and run the docs test (below).

## Non-happy paths

- **The owner chooses a Bucket 2 TLS feature instead of "warning only"
  (DESIGN-R3 §2.1).** Ship edit 1 and edit 3 only. Hold edit 2 until that
  feature defines the transport, so the docs never describe a planned state as
  current.
- **MP-N2 lands HTTPS before this ticket.** Then "never terminates TLS" is
  false. Re-read `http_server.ex` at the implementation head, and drop or
  rewrite edit 2. MP-R3-C1-T01's HTTP-only guard fails first and signals this.

## Compatibility and rollout

n/a — docs only. Rollback means reverting the doc commit.

## Verification

```bash
env -C <worktree>/website/docs-app bun run build           # docs app builds (no broken links)
env -C <worktree>/website npx playwright test --project=brand tests/gui-docs.spec.ts
```

Expected: both pass. There is no mutation check: this is a docs-only change
with no production hunk (AGENTS.md: docs rows other than config keys are
review-enforced).

Review checklist: every sentence added maps to a row in the evidence table
above, and no sentence recommends a specific HTTPS method.

## Completion and handoff

- [ ] The approved copy is applied verbatim, or with the owner's edits.
- [ ] "Refuses to start" no longer appears without the clarification.
- [ ] The banner decision is applied as chosen.
- **Docs pages:** this ticket *is* the docs change (`reference/` row is
  inapplicable; the page is the existing operator reference).
- **Dependents:** MP-N2's docs ticket links § Transport. MP-R4-C1-T01 edits a
  different section of the same page.
