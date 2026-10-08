---
design_task: DESIGN-R3
feature_id: MP-R3
owner: Kevin
status: open (awaiting explicit approval)
blocks: [MP-R3-C1-T01, MP-R3-C2-T01]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R3 (waived entries excluded). Earlier wording: every MP-R3 implementation ticket (MP-R3-C1-T01..T02, MP-R3-C2-T01..T02)"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R3/plan.md
---

Executor decisions recorded in [EXECUTOR-APPROVALS.md](EXECUTOR-APPROVALS.md) (2026-10-08).

# DESIGN-R3 — Kevin: confirm that optional Tailscale changes nothing you see

**MP-R3 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's explicit
written approval.

## 1. What this gate confirms

MP-R3 adds guard tests and a docs clarification. It changes no runtime
behaviour.

- [ ] **No user-facing change is intended.** These all stay identical:
  - the dashboard bind default (`127.0.0.1`);
  - the precedence `--host` > `server.host` > `AIUR_DEFAULT_DASHBOARD_HOST`;
  - the credential guard;
  - every error and warning message in `Aiur.HttpServer`;
  - the launcher's `Dashboard:` line.
- [ ] **No new config key.** There is no `server.tailscale` key and no
  exposure profile. Your private tailnet setup stays exactly as it is: an
  explicit `server.host` plus dashboard credentials.

## 2. Decisions needing your input

1. **Plain HTTP beyond a tailnet.** Aiur serves HTTP only. On a LAN bind
   (`0.0.0.0`) the Basic Auth password travels in cleartext.
   - Recommended: document a warning only (plan § 5).
   - Alternative: open a Bucket 2 TLS or exposure-profile feature.
   - Choose: [ ] warning only  [ ] open a Bucket 2 feature.
2. **Historical Draft spec banner.** `docs/voice-mode/spec.md` treats Tailscale
   as the access path.
   - Recommended: **leave historical specs untouched**, because they are dated
     records; the current docs pages carry the correction.
   - Choose: [ ] add a one-line "Tailscale is one supported network" banner
     [ ] leave historical specs untouched.

## 3. Copy to approve (docs only)

This is the § Tailscale addition to `website/docs-app/reference/optional-optimizations.md`:

> Tailscale decides who can *reach* the dashboard and encrypts the path. It
> never decides who is *allowed in*: every route still requires dashboard
> credentials, the supervisor token, or a webhook signature, whatever address
> the dashboard binds. Beyond loopback, without a tailnet, Basic Auth crosses
> the network in cleartext.

And the § Transport paragraph in the same page (MP-R3-C2-T01; Phase D, CR-R3-1). It
names no HTTPS method, so it does not pre-empt DESIGN-N2 §transport:

> Aiur serves the dashboard over plain HTTP and never terminates TLS. Off the
> machine, encryption is the network's job — a tailnet encrypts the path; a LAN
> does not. Browsers allow the microphone only on HTTPS or `localhost`, so
> dashboard dictation is disabled on a plain-HTTP address beyond loopback.

Evidence: `http_server.ex:64,147`; `conversation-voice-controller.js:18-19`; MDN
`getUserMedia` secure-context note (accessed 2026-10-06).

- [ ] Both paragraphs approved as written, or with edits: ______

## 4. States

There are no new screens and no new states. The existing states (listener
bound; listener disabled because credentials are missing; port in use) are
unchanged.

## 5. Acceptance

The gate is complete when the boxes in §§ 1–3 carry your approval.
