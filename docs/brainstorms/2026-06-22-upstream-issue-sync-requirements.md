# Upstream → fork issue sync — design / requirements

- Issue: [#344](https://github.com/aiur-team/aiur/issues/344)
- Status: **Design — awaiting operator decision. No implementation yet.**
- Date: 2026-06-22

## 1. Problem

Aiur reads work from the **same repo it is configured against** (`tracker.github.repo`).
In a fork-based setup — an agent GitHub account that owns a **fork** and opens PRs
to it, deliberately **without write access to the real (upstream) repo** — the
up-to-date issues live **upstream**, not in the fork. Today the operator has to
hand-clone upstream issues into the fork before Aiur's poll loop can pick them up.

We want Aiur to learn about an upstream repo and **synchronize issue state from
upstream into the local/fork repo**, so the agent can work upstream-tracked issues
while still branching and PRing against the fork.

## 2. Goals / non-goals

**Goals**
- Discover an upstream repo (auto-detect and/or explicit config).
- Periodically mirror matching upstream issues into the fork as **stub issues**
  the existing poll loop already understands (`agent:todo`, `complexity:*`, etc.).
- Be **idempotent**: re-polls update existing stubs, never duplicate them.
- Reflect upstream lifecycle changes (close / relabel) onto the stub so stubs
  don't silently go stale.

**Non-goals (v1)**
- Writing anything back to upstream (the premise is no upstream write access).
- Mirroring upstream issue **comments** into the stub.
- Syncing PRs, milestones, projects, or assignees.
- Linear upstreams — this is GitHub-fork specific (Linear tracker is untouched).

## 3. Current architecture (verified extension points)

All citations checked against the working tree at `c68116d`.

| Concern | Where | Notes |
|---|---|---|
| Tracker contract | `src/lib/aiur/tracker.ex:8` | `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, `create_comment/2`, `update_issue_state/2`, `add_label/2`, `remove_label/2` |
| GitHub adapter | `src/lib/aiur/github/tracker.ex` → `src/lib/aiur/github/client.ex` | REST API via `Req` (`@base_url "https://api.github.com"`), Bearer token. **Not** the `gh` CLI. |
| Candidate fetch | `github/client.ex:12` (`fetch_candidate_issues/1`) | Lists issues per label (`agent:todo`, `agent:in-progress`), dedups by id. Label filter = `?labels=…&state=open`. |
| Config schema | `src/lib/aiur/config/schema.ex:40` (`Github`), `:77` (`Tracker`) | Ecto embedded schema. `Github` has `repo`, `label_prefix`, `bot_account`. Add a field → add to `embedded_schema` + `cast/3`. |
| Config accessors | `src/lib/aiur/github/config.ex` | `repo/0` (falls back to `Aiur.Git.origin_repo/0`), `token/0` (`GITHUB_TOKEN`), `label_prefix/0`, `validate!/0`. |
| Init wizard | `src/lib/aiur/init.ex` | `detect_repo/0` (`init.ex:1307`) parses `git remote get-url origin`. Prompts for tracker/repo, writes YAML, creates labels (`setup_labels`). |
| Poll loop | `src/lib/aiur/orchestrator.ex:741` (`maybe_dispatch/1`) | GenServer tick every `polling.interval_seconds` (default 30, `schema.ex:111`). Calls `Tracker.fetch_candidate_issues/0` at `:747`. `poll_github_firehose/1` at `:729` already does an out-of-band GitHub pass each tick — natural sibling for a sync pass. |
| Labels | `src/lib/aiur/github/labels.ex` | Label families `agent:*`, `model:*`, `complexity:*`, `model:remote` are created in the fork at init. `add_label`/`remove_label` are idempotent (404-on-remove treated as success). |
| Auth | `github/config.ex:27` | Single `GITHUB_TOKEN` env var, repo-write scope, used for every call. |

**Implication:** the cleanest insertion point is a new **sync pass** that runs at
the top of each poll tick (next to `poll_github_firehose/1`), reads upstream via a
read path, and reconciles stub issues in the fork. The existing
`fetch_candidate_issues/0` then picks the stubs up unchanged — no dispatch-path
rewrite needed.

## 4. Proposed design (recommended path)

A new module, e.g. `Aiur.GitHub.UpstreamSync`, invoked once per poll tick when
`tracker.github.upstream_repo` is set:

1. **List upstream candidates** — `GET /repos/{upstream}/issues?labels=<filter>&state=open`
   using the configured label filter (default: the `agent:todo` state label;
   optionally a named section / arbitrary label).
2. **For each upstream issue**, compute the dedup key and **ensure a fork stub**:
   - If no stub exists → create one in the fork.
   - If a stub exists → reconcile its title, labels, and open/closed state.
3. **Reconcile removals** — if a previously-synced upstream issue no longer matches
   the filter (closed, relabeled), reflect that onto the stub (see §6).

**Stub issue shape (recommended):**

```
Title:  <upstream title>

Body:
<!-- aiur-upstream: owner/repo#NNN -->
Mirrored from upstream issue: https://github.com/owner/repo/issues/NNN

> (optional, configurable) first N lines / full body of the upstream issue

Labels: upstream:sync, agent:todo, complexity:3, model:claude  (mirrored families only)
```

- The HTML comment `<!-- aiur-upstream: owner/repo#NNN -->` is the **authoritative
  dedup key** (carries the exact upstream coordinate, survives title edits).
- The `upstream:sync` label is a cheap **filter/marker** for listing all stubs in
  one query and for the operator to eyeball "this was bot-created."
- The agent works the stub in the fork and opens its PR against the fork. The PR's
  `Closes #<stub>` closes the **stub**; the human merging upstream closes the
  upstream issue out-of-band.

This keeps the change additive: one new module + one new config key + one optional
init prompt + one call site in the poll tick.

## 5. Key decisions (operator must choose)

These are the decisions the issue asks to settle before implementation. Each lists
options with my **recommendation in bold** and why.

### D1 — Upstream discovery: how does Aiur learn the upstream repo?
- **A. Both auto-detect + explicit config (recommended).** At `aiur init`, detect a
  likely upstream via the GitHub fork `parent` (`GET /repos/{owner}/{repo}` →
  `.parent.full_name`) and/or an `upstream` git remote; prompt *"Detected upstream
  `<owner/repo>`. Sync issues from it?"*. Always allow setting
  `tracker.github.upstream_repo` directly (and a non-interactive init flag).
  Auto-detect only pre-fills the explicit key.
- B. Explicit config only — simplest, but loses the nice init UX the issue calls for.
- C. Auto-detect only — magical, brittle when there's no `parent`/`upstream` remote.

### D2 — Sync direction / state flow
- **A. One-way upstream → fork, with lifecycle reflection (recommended).** Read-only
  on upstream. Mirror create + title/label changes + close onto the stub. **Nothing**
  is ever written upstream. Matches the no-write-access premise.
- B. One-way, create-only (no reflection) — stubs go stale when upstream closes/relabels.
- C. Bidirectional — contradicts the premise (no upstream write); explicitly discouraged.

### D3 — Stub format + dedup mechanism
- **A. Hidden HTML marker (key) + `upstream:sync` label (filter) (recommended).**
  Dedup key = `owner/repo#NNN` parsed from the marker comment; label for cheap listing
  and operator visibility. Most robust against title edits and hand-created collisions.
- B. Label only (`upstream:sync` + store number elsewhere) — weaker key, label text is lossy.
- C. Marker only (no dedicated label) — robust key but every "list all stubs" needs a body scan.

  Sub-decision (body content): pointer-only **(recommended default)** vs. mirror first
  N lines vs. mirror full upstream body. Pointer-only avoids drift and keeps the stub small;
  the agent clicks through to upstream for detail.

### D4 — Label translation when the fork lacks an upstream label
- **A. Mirror known Aiur families, skip unknown (recommended).** Copy only
  `agent:*`, `complexity:*`, `model:*` (+ `model:remote`) — these are guaranteed to
  exist in the fork because init creates them. Any other upstream label is ignored.
  No surprise label creation in the fork.
- B. Create missing labels — fork accumulates arbitrary upstream labels (color/description drift).
- C. Map via a configurable translation table — most flexible, most config surface; YAGNI for v1.

## 6. Open questions — resolved vs. deferred

| Question | Recommended resolution |
|---|---|
| Stub when upstream **closes**? | Close the stub (and add `agent:cancelled`/comment) so the poll loop stops considering it. Reopen if upstream reopens. (Part of D2-A.) |
| Stub when upstream **relabeled** (e.g. todo→done)? | Re-mirror the known-family labels each pass; drop labels no longer present upstream. |
| Mirror **comments**? | No (v1). Pointer only. Revisit if agents need upstream discussion context. |
| **Auth** — one token or two? | Default: single `GITHUB_TOKEN` (works when upstream is public — the common OSS-fork case). Optional `GITHUB_UPSTREAM_TOKEN` (read-only) for **private** upstreams, falling back to `GITHUB_TOKEN` when unset. Recommend shipping the single-token path first; the optional second token is a small additive follow-up. |
| **Rate limits / cadence**? | Reuse the existing poll tick (default 30s). One extra `GET issues` list call + at most a few writes per new/changed upstream issue. Gate the sync pass behind a min-interval (e.g. ≥ 60s) so a fast poll interval doesn't hammer the API. Honor `X-RateLimit-Remaining`. |
| **Collisions** with hand-created stubs? | The marker is the dedup key. Before creating, search the fork for the marker; if an operator pre-made an issue with the same marker, adopt it instead of duplicating. Never touch fork issues lacking the marker. |

## 7. Risks

- **Stub/upstream divergence** if reflection is partial — mitigated by re-mirroring
  known fields every pass (D2-A) rather than create-only.
- **Label drift** if we auto-create upstream labels — avoided by D4-A (skip unknown).
- **API spend** on large upstreams — mitigated by label-filtered list + min-interval gate.
- **Accidental upstream writes** — structurally prevented: the sync path has no
  upstream write calls; only the fork token is used for mutations.

## 8. After the operator picks

Once D1–D4 are chosen:
1. Write acceptance criteria into the issue.
2. `ce-plan` a short implementation plan (config key + accessor, `UpstreamSync`
   module, poll-tick call site, init prompt, tests).
3. Implement under TDD, open a draft PR to the fork, self-review with `ce-code-review`.

**No implementation proceeds until D1–D4 are decided.**
