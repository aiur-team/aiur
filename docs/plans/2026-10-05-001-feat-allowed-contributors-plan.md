---
title: Allowed Contributors - Plan
date: 2026-10-05
issue: aiur-team/aiur#2957
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Allowed Contributors - Plan

## Goal Capsule

- **Objective:** let a repository name outside accounts and orgs whose new issues wake the Executor as `allowed_contributor` intake, and make sure nobody else can produce that wake.
- **Product authority:** issue aiur-team/aiur#2957 (spec, security requirements, required adversarial review).
- **Open blockers:** none.

## Product Contract

### Summary

The target repository's default branch can hold an `.github/ALLOWED-CONTRIBUTORS` file that names GitHub accounts and orgs by numeric id. When a verified, non-bot author on that list opens an issue, Aiur writes one rate-limited, identifier-only `issue.opened.allowed_contributor` wake into the Executor wake feed and logs the decision. The `aiur-run` skill tells the Executor to triage those tickets first and to treat their content as untrusted.

### Problem Frame

Today intake from trusted outside contributors is a hand-maintained table in `CONTRIBUTING.md` ("Executor issue intake"). Nothing tells the Executor when one of those accounts files an issue, and the table keys on logins, which can be renamed or re-registered. Dispatch itself is not creator-gated: the trigger label's applier must be in `tracker.github.allowed_users`. That invariant is documented in `Aiur.GitHub.DispatchAuthorization`, and it is why an outside contributor's own labelling is refused.

### Key Decisions

- **Allow-listed status grants intake, never dispatch authority.** An allowed contributor's issue becomes dispatchable the same way an operator-filed one does: a trusted applier (the Executor or operator, through `allowed_users`) applies `agent:todo`. A contributor's own labelling, or their edits, never authorize dispatch. This keeps the "no creator short-circuit" invariant in `DispatchAuthorization` intact. A compromised allowed account can produce a capped number of wakes but cannot run an agent.
- **One file location: `.github/ALLOWED-CONTRIBUTORS`, with no `.aiur/` fallback.** A second location would create a precedence rule that an attacker could exploit by adding the file nobody watches.
- **The file stores numeric ids, and logins are comments only.** Users are matched by id alone. Orgs carry both an id and a login: the login addresses the REST endpoint, and the id must match the API response, so an org rename or a re-registered org name fails closed.
- **Org membership uses REST `GET /orgs/{org}/memberships/{username}` with the operator's token.** It counts only `state: active`, and only when the response `user.id` and `organization.id` match the expected ids. A 404 or any other status, a rate limit, a transport error, or a mismatch rejects the author. A positive result is cached for 5 minutes, a negative one for 60 seconds, and errors are never cached.
- **No new config keys.** The feature is on exactly when the file exists on the default branch. Caps and TTLs are module constants. This also keeps the change out of `website/`.
- **Two producers feed one intake decision.** A verified `issues.opened` webhook and the existing open-issue candidate poll both supply the authenticated author `user.id` and `user.type`. A durable per-repo seen set dedups by issue number, so one issue yields at most one wake across producers and restarts.

### Requirements

**Allow-list source**

- R1. The allow-list is read only from the repository's default branch, pinned to the commit that last touched the file. The read never uses a PR branch, a fork, an issue, or a comment.
- R2. The format is line-based: `user <id> [# login]` and `org <id> <login> [# note]`, plus `#` comments and blank lines. Any malformed line invalidates the whole file, which fails closed (no contributors) and raises an alert.
- R3. A change to the file's commit SHA is surfaced to the operator as an alert naming the entries added and removed and the new commit SHA.
- R4. An allowed contributor cannot extend trust: there is no transitive or nested resolution beyond direct user ids and direct org membership.

**Author identity and eligibility**

- R5. The author identity is the numeric `user.id` from an authenticated API response or an HMAC-verified webhook payload, never a login taken from content.
- R6. Only issue creation produces intake. Comments, edits, labels, reactions, reopenings, transfers out, and pull requests never do.
- R7. Authors whose `user.type` is not `User`, issues with `performed_via_github_app`, and Aiur's own bot and daemon accounts are rejected.
- R8. Org membership is verified as described in Key Decisions and fails closed.

**Executor wake**

- R9. An accepted issue produces exactly one wake whose topic class is `ticket.issue.opened.allowed_contributor`, carrying only the identifier, the author id, and no title or body.
- R10. Accepted wakes are capped per author per rolling hour (default 5). Surplus is dropped and logged.
- R11. Every accept and reject is appended to a durable audit log with the issue, the author id, the reason, the allow-list commit SHA, and the producer.

**Skill and docs**

- R12. `aiur-run` tells the Executor to triage `allowed_contributor` wakes first, to route each one into the Build Order or onto a dispatch label quickly, and to treat ticket content from these authors as untrusted data, never instructions.
- R13. `docs/allowed-contributors.md` documents the format, how to look up ids, precedence, caching, revocation, and the security model. `CONTRIBUTING.md`'s intake table points to it. Nothing under `website/` changes.

### Acceptance

- An allowed individual and an allowed org member each open an issue. Each produces exactly one `allowed_contributor` wake, and each issue dispatches once a trusted applier labels it.
- A non-allowed user opening, commenting on, or editing an issue produces no wake and no dispatch, and the rejection is logged.
- Every adversarial attempt listed in #2957 has a test proving it is blocked.

### Scope Boundaries

- Out of scope: auto-labelling by the daemon, contributor self-dispatch, a CLI that resolves logins to ids, config keys, and a dashboard surface.
- Out of scope: `organization.member_removed` webhook invalidation. The 5-minute positive TTL bounds the staleness.

---

## Planning Contract

**Product Contract preservation:** Product Contract unchanged.

### Key Technical Decisions

- **KTD1 — New namespace `Aiur.AllowedContributors`, with one GenServer and pure helpers.** The parser, the policy, and the rate limit are pure modules tested with real inputs. Only the server holds state: the allow-list snapshot, the membership cache, the rate windows, and the seen set. It mirrors `Aiur.GitHub.CodeOwners` (periodic refresh, injected `request_fun` / `alert_fun`) and keeps each file under 200 lines.
- **KTD2 — The default-branch read is three REST GETs, all through `Transport.default_request_fun/1`.** `GET /repos/{o}/{r}` gives `default_branch`. `GET /repos/{o}/{r}/commits?sha=<branch>&path=.github/ALLOWED-CONTRIBUTORS&per_page=1` gives the pinning commit SHA. `GET /repos/{o}/{r}/contents/.github/ALLOWED-CONTRIBUTORS?ref=<sha>` gives the base64 body at exactly that commit. An empty commit list or a 404 on contents means the file is absent. Any other failure keeps the previous snapshot when one exists, or fails closed when none does. The refresh runs every 10 minutes, and an observe-time read happens only when no snapshot is held. No GraphQL is used.
- **KTD3 — Membership uses `GET /orgs/{org_login}/memberships/{user_login}`.** An author counts only on HTTP 200 with `state == "active"`, `user.id == author_id`, and `organization.id == org_id`. A 404 caches a negative result for 60 s. A 200 that fails a check also caches negative and logs `org_id_mismatch`, `user_id_mismatch`, or `membership_pending`. A rate limit, 5xx, transport error, or 403 is not cached and rejects with `membership_unverified`. A positive result is cached for 300 s under the key `{org_id, author_id}`.
- **KTD4 — Producers hand the server a normalized candidate and never a raw payload.** The candidate is `%{number, author_id, author_login, author_type, via_app?, created_at, source}`. The webhook producer builds it from `issue.user` (never `sender`) of an `issues` delivery with `action == "opened"`, after HMAC verification and the tracked-repo match. The poll producer builds it from `Issue` structs that gain `creator_id`, `creator_type`, and `created_via_app?`. The poll considers only issues created within the last 24 h, which bounds the first-boot backlog.
- **KTD5 — A durable seen set provides exactly-once delivery.** `<executor-state-dir>/<repo>.allowed-contributors.seen.json` maps the issue number to its decision time and is pruned after 7 days. A number is recorded on its first terminal decision, whether accept or reject, so neither a poll re-sighting nor a restart re-wakes. A rate-limited candidate is also terminal (dropped, not deferred), which honors the issue's drop semantics. A decision that was only deferred (`allowlist_unavailable`, `membership_unverified`) is not recorded, so a later sighting re-evaluates it. That re-evaluation is what makes a transient fail-closed decision recoverable.
- **KTD6 — The wake travels on the existing bus.** `Publisher.publish("ticket.<n>.issue.opened.allowed_contributor", payload, bypass_contamination: true, dedup_key: …)`. A new `ExecutorBindings` default, `{"ticket.*.issue.opened.allowed_contributor", "intake:auto"}`, makes the listener project it. The projection gains one typed field, `author_id`, and the payload never carries a title or body.
- **KTD7 — The audit log is ndjson through `DecisionLog.append/2`** at `<executor-state-dir>/<repo>.allowed-contributors.audit.ndjson`. Each record also produces one `Logger.info` line with the same fields.
- **KTD8 — Allow-list changes alert through `Alerts.emit_custom("allowed_contributors.changed", …)`** with the added and removed entries and both SHAs. A malformed file alerts through `allowed_contributors.invalid`. Both alerts are one-shot per SHA.

### High-Level Technical Design

```mermaid
flowchart LR
  WH[Webhook issues.opened<br/>HMAC-verified, tracked repo] --> C[candidate]
  PL[Open-issue poll<br/>created < 24h] --> C
  C --> S{seen?}
  S -- yes --> X[drop silently]
  S -- no --> P{shape policy<br/>User, no app, not Aiur}
  P -- reject --> A[audit + seen]
  P -- ok --> L{allow-list snapshot<br/>default-branch SHA}
  L -- unavailable --> D[audit deferred]
  L -- user id match --> R{rate limit<br/>5/author/h}
  L -- org entries --> M{membership REST<br/>id-verified, cached}
  M -- member --> R
  M -- not member --> A
  M -- error --> D
  R -- over --> A
  R -- ok --> W[publish wake + audit + seen]
```

---

## Implementation Units

### U1. Allow-list file parser

**Goal:** a pure parser and differ for the file format.
**Requirements:** R2, R4.
**Dependencies:** none.
**Files:** `src/lib/aiur/allowed_contributors/file.ex`, `src/test/aiur/allowed_contributors/file_test.exs`.
**Approach:** parse the text into `%{users: MapSet<int>, orgs: %{id => login}}` or return `{:error, {:line, n, reason}}`. Ids are positive decimal integers with no sign and no leading zero, up to 19 digits. An org login must match GitHub's org-login charset (ASCII alphanumerics and single hyphens, 1–39 characters). Trailing `#` comments are stripped. Unknown keywords, duplicate conflicting org ids, and a file over 64 KiB are errors. `diff/2` returns the added and removed entries.
**Test scenarios:**
- A valid mixed file parses, and a trailing login comment is ignored.
- Blank lines and comment-only lines are ignored, and an empty file yields an empty allow-list.
- A bare login line (`octocat`) is rejected, because logins are never identities.
- A unicode-lookalike digit (`１２３`), a negative id, `0`, or a leading-zero id is rejected.
- An `org` line with no login, or with a non-ASCII or lookalike login, is rejected.
- An unknown keyword (`team`, `include`, `@org/team`) is rejected, with no transitive forms.
- `diff/2` reports an added user and a removed org.

### U2. Default-branch source

**Goal:** fetch the file at the commit that last touched it on the default branch.
**Requirements:** R1, R3.
**Dependencies:** U1.
**Files:** `src/lib/aiur/allowed_contributors/source.ex`, `src/test/aiur/allowed_contributors/source_test.exs`.
**Approach:** implement KTD2 with an injected `request_fun`. Return `{:ok, %{sha, allowlist}}`, `{:ok, :absent}`, or `{:error, reason}`. The branch is always the repository's `default_branch` from the API, never `tracker.base_branch` and never a configured ref.
**Test scenarios:**
- The happy path decodes the base64 body, and the commit SHA is pinned in the contents `ref`.
- The default branch name comes from the repo API, and the requests never name a PR head, a fork, or another branch.
- An empty commit list is `:absent`, and a contents 404 is `:absent`.
- A 403, a rate limit, or a malformed body returns `{:error, _}`.

### U3. Org membership check

**Goal:** id-verified org membership with a bounded cache.
**Requirements:** R8.
**Dependencies:** none.
**Files:** `src/lib/aiur/allowed_contributors/membership.ex`, `src/test/aiur/allowed_contributors/membership_test.exs`.
**Approach:** implement KTD3 as a pure `check(cache, org, author, now, request_fun, token)` that returns `{verdict, cache}`. The verdict is `:member`, `{:not_member, reason}`, or `{:unverified, reason}`.
**Test scenarios:**
- An active member returns `:member` and is cached, and a second call within 300 s makes no request.
- A pending membership is `{:not_member, :membership_pending}`.
- A 404 for an outside collaborator is negative, cached for 60 s, and rechecked after 60 s.
- A user who left after a positive result: past 300 s the check re-requests and sees the 404, so the stale cache expires.
- A response with a different `user.id`, from a renamed or reused login, is `user_id_mismatch`.
- A response with a different `organization.id`, from an org rename with the name re-registered, is `org_id_mismatch`.
- A 403, a 429, a 5xx, or a transport error is `{:unverified, _}` and is not cached.

### U4. Intake server, policy, rate limit, and audit

**Goal:** the decision point that turns candidates into wakes.
**Requirements:** R5–R11.
**Dependencies:** U1, U2, U3.
**Files:** `src/lib/aiur/allowed_contributors.ex` (GenServer), `src/lib/aiur/allowed_contributors/policy.ex`, `src/lib/aiur/allowed_contributors/rate_limit.ex`, `src/lib/aiur/allowed_contributors/audit.ex`, `src/lib/aiur/allowed_contributors/seen.ex`, plus `src/test/aiur/allowed_contributors/{policy,rate_limit,seen,server}_test.exs`.
**Approach:** `observe(candidate, server)` is a synchronous call, so the producers and tests have a barrier. The policy is pure and checks, in order: the candidate's well-formedness (`author_id` a positive integer), `author_type == "User"`, `not via_app?`, and not an Aiur login. The server then applies the seen set, the snapshot, the user-id match, then the orgs in id order (stopping at the first `:member`), then the rate limit, then publish. Every outcome goes to the audit log with the SHA (`nil` when no snapshot is held) and the source. All seams are injected: `request_fun`, `publish_fun`, `alert_fun`, `now_fun`, and the paths.
**Test scenarios:**
- Covers Acceptance 1: an allowed user id produces one publish on the `allowed_contributor` topic, one audit `accept` naming the SHA, and the issue is recorded as seen.
- Covers Acceptance 1: an allowed org member produces one publish with `via` set to the org.
- A second observe of the same number, from either source, produces no publish.
- Covers Acceptance 2: a non-allowed author produces no publish and an audit `reject` with `not_allowed`.
- An absent file, or a malformed file, rejects everyone and alerts once for `invalid`.
- A snapshot fetch error with no prior snapshot defers, with no publish and no seen record. A later observe after recovery accepts.
- A SHA change alerts `changed` with the diff, and a refresh that returns the same SHA does not alert.
- The rate limit admits 5 per author per hour, drops and audits the 6th with `rate_limited`, and readmits after the window slides. Another author is unaffected.

### U5. Producers, bindings, and supervision

**Goal:** wire both producers and the wake path.
**Requirements:** R5, R6, R9.
**Dependencies:** U4.
**Files:** `src/lib/aiur/events/github_webhook.ex`, `src/lib/aiur/github/issues.ex`, `src/lib/aiur/issue.ex`, `src/lib/aiur/executor_bindings.ex`, `src/lib/aiur/executor_wake_projection.ex`, `src/lib/aiur.ex`, plus tests in `src/test/aiur/events/github_webhook_test.exs`, `src/test/aiur/executor_wake_projection_test.exs` (or the existing projection test), and `src/test/aiur/allowed_contributors/producers_test.exs`.
**Approach:** `handle_delivery/3` calls an injected `:allowed_contributor_fun` only for `"issues"` deliveries with `action == "opened"` that pass `Normalizer.tracked_repo/2`. `normalize_issue` populates the new `Issue` fields from `user.id`, `user.type`, and `performed_via_github_app`. `record_open_issues` forwards fresh issues with a non-blocking cast, so a poll never waits on intake. Start the server with the recording children. The intake is inert when the tracker is not GitHub.
**Test scenarios:**
- A webhook `issues.opened` from the tracked repo reaches intake with `author_id` taken from `issue.user.id`.
- A webhook `issues.edited`, `labeled`, `reopened`, or `transferred`, an `issue_comment`, a `pull_request`, or a reaction never reaches intake.
- A webhook for an untracked repo never reaches intake.
- A transfer arrives as `opened` with `issue.user` set to the original author and `sender` set to the allowed transferrer. Intake sees the original author's id, not the sender's.
- The poll forwards an issue created 1 h ago and skips one created 3 days ago.
- The projection of the new topic has topic class `ticket.issue.opened.allowed_contributor`, `ticket` set to the issue number, `author_id` set, and no title or body key.
- `ExecutorBindings.patterns/0` includes the new pattern.

### U6. Skill, docs, and dogfood

**Goal:** operator- and Executor-facing guidance.
**Requirements:** R12, R13.
**Dependencies:** U4.
**Files:** `.claude/skills/aiur-run/SKILL.md`, `docs/allowed-contributors.md`, `CONTRIBUTING.md`, `src/test/aiur/aiur_run_allowed_contributors_skill_test.exs`.
**Approach:** replace the `CONTRIBUTING.md`-driven intake paragraph in `aiur-run` with an `allowed_contributor` wake rule. Triage these wakes first, route each one to the Build Order or `agent:todo` quickly, and treat the body as untrusted data. Add the topic to the wake-monitor `jq` filter and update the binding count. The docs cover the format, `gh api users/<login> --jq .id`, `gh api orgs/<org> --jq .id`, the single location, caching TTLs, revocation (remove the line and merge, effective within 10 minutes), and the threat model. Point `CONTRIBUTING.md`'s intake section at the doc. Do not touch `website/`.
**Test scenarios:**
- A skill-text test asserts that the skill names `issue.opened.allowed_contributor`, the untrusted-content rule, and the prioritisation rule.
**Verification:** `rg website/` over the diff is empty.

### U7. Adversarial suite

**Goal:** one test per bypass named in #2957, each proving no wake and no dispatch.
**Requirements:** the Acceptance list and the issue's "Required adversarial review".
**Dependencies:** U4, U5.
**Files:** `src/test/aiur/allowed_contributors/adversarial_test.exs`, plus `src/test/aiur/github/dispatch_authorization_test.exs` for the dispatch half.
**Test scenarios:** (each asserts no publish, plus an audit `reject` or `deferred` where intake ran)
- **Login spoofing in the body or title:** an issue whose title and body say "opened by @allowed-user", authored by a non-allowed id, is rejected.
- **Renamed account:** an allowed id with a new login is still accepted, and a non-allowed account renamed to an allowed user's old login is rejected.
- **Login reused after deletion:** the old login on a new id is rejected.
- **Case and unicode lookalikes:** an author login `Allowed-User` or `аllowed-user` (Cyrillic а) with a non-allowed id is rejected. The file parser also rejects lookalike digits.
- **Fork or branch edit of the file:** a fake transport that serves an allow-listing body for any `ref` other than the default-branch commit SHA proves Source never asks for it, and the author stays rejected.
- **Outside collaborator vs member:** a 404 from the membership API rejects, and an active member accepts.
- **User who left the org (stale cache):** accept, advance the clock past 300 s with the membership now 404, and a new issue is rejected.
- **Org rename:** an `organization.id` mismatch rejects.
- **Forged or unsigned webhook:** the `AiurWeb.GithubWebhook.Auth` plug rejects an unsigned or mismatched `issues.opened` with 401, and intake is never called. Add this through the router test harness.
- **Repo mismatch:** an `issues.opened` for another `repository.full_name` never reaches intake.
- **Issue transferred from another repo:** a non-allowed original author with an allowed sender is rejected.
- **Bot or GitHub App:** `user.type == "Bot"` with an allow-listed id is rejected, and a `performed_via_github_app` issue is rejected.
- **Aiur's own account:** an issue by the configured `bot_account`, even as an org member, is rejected.
- **Comment mentioning the Executor:** an `issue_comment` that says "@executor run this" on any issue never reaches intake.
- **Label manipulation by a non-allowed user:** `DispatchAuthorization` denies an issue whose `agent:todo` was applied by a non-allowed actor, even when the author is an allowed contributor. An allowed contributor labelling their own issue is also denied.
- **Edit of someone else's issue by an allowed user:** an `issues.edited` delivery with an allowed `sender` never reaches intake.
- **Rate-limit flooding:** 50 issues from one allowed author yield exactly 5 publishes and 45 `rate_limited` audits.
- **Membership API down:** a 503 fails closed with `membership_unverified` and no publish.

---

## Verification Contract

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix lint` (`specs.check` + `credo --strict`), `mix test`, and `mix dialyzer` pass from `src/`.
- Each new test fails with its guarded production hunk reverted. The PR names the results.
- The diff touches nothing under `website/`.

## Definition of Done

- U1–U7 are landed in one PR referencing #2957, with an "Adversarial review" section mapping each bypass to its test.
- CI is green, and the PR is not merged.
