# Security branch — trust-boundary research pack

Status 2026-07-30: code-side map **verified in source**; GitHub-side
authorization research re-running (first attempt died on API overload).
This doc is the canonical context for the ~4 security tickets (not yet
filed — numbers TBD).

## Goal (operator directive, verbatim intent)

Only `its-everdred` and `its-applekid` may cause Aiur to spin up agents,
feed instructions to agents, or get code into aiur — via issue creation,
label application, PR/issue comments, or any other inbound flow.
Adversarial framing: attacker can open issues, comment, and open fork PRs.

## Verified environment

- Repo **public**. Collaborators exactly `its-everdred` (admin) and
  `its-applekid` (push+triage) — nobody else can apply labels.
- `.github/CODEOWNERS`: `* @its-everdred @its-applekid`.
- CI uses `pull_request:` (not `pull_request_target:`) → fork PRs get no
  secrets today.

## The defense that works (do not break it)

`events_digest.ex:34-42` drops GitHub-sourced events from non-CODEOWNERS
authors **before the agent prompt**; they stay visible in the issue log +
dashboard. Trust stamped at publish (`sanitizer.ex:103-128`) and persisted
so replays carry it (`issue_log.ex:164,193,550`). Consumers:
comment_wake.ex:223, pr_command_scanner.ex:117-118, command_scan.ex:104.

The scan's headline "anyone can label to dispatch" is **false** on this
repo: labels need triage+, and only the two trusted logins have it. The
issue-creator gap is real but currently unreachable for outsiders.

## Real gaps → the four tickets

1. **Ingestion allowlist + provenance (defense-in-depth).**
   - No `creator`/author field on the Issue struct; `DispatchPolicy.
     candidate_issue?` (dispatch_policy.ex:338-356) never checks who
     created/labelled. Protection rests entirely on GitHub role config —
     one accidental collaborator add away from open.
   - Add `tracker.allowed_users` (or similar) to the config schema
     (tracker.ex has no such field); enforce server-side at ingestion.
   - Who applied a label is NOT in the issues API — needs the timeline/
     events API (`labeled` event, `actor` field). Verify endpoint in the
     re-run research.
2. **Fail-closed trust defaults + workpad cutoff.**
   - `events_digest.ex:71` `_ -> true` (non-github source passes) and `:76`
     `author_trusted_for_digest?(_), do: true` (non-map event passes).
     Default closed instead.
   - `comment_context.ex:110-122`: unaddressed PR review threads skip
     `comments_after_workpad/2` (siblings at :97-108 apply it). Replay/loop
     bug; digest filter still applies, so injection severity is low but
     real.
3. **CODEOWNERS single point of failure.**
   - Empty/missing file silently narrows trust to repo owner
     (code_owners.ex:151-195) — degradation is silent. Alert loudly;
     optionally cross-check against the config allowlist from (1).
4. **Merge gate + CI trigger hardening.**
   - `comment_wake.ex:64` marks issue done on PR merge with no check of
     who merged. Enforce via ruleset/branch protection (required review
     from CODEOWNERS, require last-push approval, no self-approval) and
     verify in code where cheap.
   - Guard test that no workflow ever adopts `pull_request_target` with a
     PR-head checkout.
   - Comment bodies reach prompts with truncation+secret-redaction only
     (sanitizer.ex layers; semantic framing deferred to render). Ensure
     external text is fenced as data at render, least-privilege daemon
     token (relates to #678 token exhaustion).

## GitHub-side research findings (verified 2026-07-30)

- **CODEOWNERS ≠ label allowlist.** It controls review routing only; label
  application is gated by the **triage+ role**, a separate system. Audit
  (a) collaborators with triage+ and (b) any App/Action holding
  `issues: write` — all of them can apply `agent:todo`.
- **`author_association` is not an authz primitive.** `CONTRIBUTOR` is
  earned forever by one merged trivial PR; org-visibility settings can
  collapse MEMBER→NONE; precedence collapse hides trust
  (actions/github-script#643). Gate on explicit `user.login` allowlist or
  `GET /repos/{o}/{r}/collaborators/{u}/permission`; use association at
  most as a deny signal.
- **Label provenance**: the issue object has no applier info. Use
  `GET /repos/{o}/{r}/issues/{n}/timeline`, filter `type: "labeled"`,
  check the **latest** labeled event's `actor.login` against the allowlist.
- **pwn-request class**: `pull_request_target`/`workflow_run` run with base
  secrets; the durable guard is a CI policy check that **fails the build**
  if any workflow introduces those triggers (grep-gate / zizmor /
  actionlint rule) + pin third-party actions to SHAs. actions/checkout v7
  (2026-06) now fails by default on unreviewed fork checkout under those
  triggers — backstop, not substitute.
- **Prompt injection** ("Comment and Control", ~2026-04; NX build attack;
  GhostAction): fencing/sanitization (strip zero-width Unicode, HTML
  comments, base64 blobs) is a first line only — **the durable control is
  least-privilege tokens + human approval at the merge boundary**, so a
  successful injection cannot cause an irreversible privileged effect.
- **Rulesets** (prefer over classic): require PR + `required_approving_
  review_count>=1`, `require_code_owner_review`,
  **`require_last_push_approval`** (voids the stale-approval-then-push-more
  bot trick; the last pusher cannot be the approver),
  `dismiss_stale_reviews_on_push`, and **empty `bypass_actors`** — a bot in
  bypass defeats everything. Auto-merge cannot complete (and since 2026
  cannot even be enabled, HTTP 422) until all rules pass → guarantees no
  merge without a human code owner approving the latest push.
- **Daemon token**: GitHub App installation token over fine-grained PAT —
  ~1 h auto-rotating, machine identity, per-repo install. Grant only
  Contents:write, Issues:read(+write only if it must label/comment),
  PRs:write. Never Administration/Actions/Secrets/Workflows.
- **Fail closed on ambiguity**: NONE association, missing timeline actor,
  or API error verifying permission → do not run the agent. Log every
  trigger decision (actor, label event id, comment id) for forensics.
