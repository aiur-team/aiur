# GitHub API claim primitives for multi-daemon issue ownership

Research date: 2026-11-06. Current REST version header shown on docs pages: `X-GitHub-Api-Version: 2026-03-10` ([REST git refs](https://docs.github.com/en/rest/git/refs)). Labels: **[doc]** = documented guarantee, **[obs]** = observed by third parties, **[inf]** = my inference.

## 1. Issue-level writes (labels, assignees, body, comments, fields): any conditional write?

### Takeaway
No. No issue-level write on GitHub documents a compare-and-set. REST conditional requests (ETag/If-Match) are documented for GET only. Labels and assignees are additive, set-union writes, so two daemons that both "claim" an issue both get success.

### Cited Findings
- **[doc]** "Conditional requests for unsafe methods, such as `POST`, `PUT`, `PATCH`, and `DELETE` are not supported" unless an endpoint's own docs say otherwise. ETag / `if-none-match` / `if-modified-since` are described only for reads, and a 304 does not count against the primary rate limit — [Best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- **[doc]** Add labels (POST) is additive: "The labels to add to the issue's existing labels." Set labels (PUT) "Removes any previous labels and sets the new labels." The page documents no If-Match or version precondition. Status codes are 200/301/404/410/422 — [Labels](https://docs.github.com/en/rest/issues/labels)
- **[doc]** Remove a label (DELETE `/issues/{n}/labels/{name}`) "returns a 404 Not Found status if the label does not exist." The page does not say whether a label that exists in the repo but is not on the issue also returns 404 — [Labels](https://docs.github.com/en/rest/issues/labels)
- **[doc]** Add assignees "Adds up to 10 assignees". Already-assigned users are not replaced. Users without push access are "silently ignored". The only success code is 201. No precondition is documented — [Assignees](https://docs.github.com/en/rest/issues/assignees)
- **[doc]** GraphQL mutations that do carry an expected-value precondition are ref and PR mutations (`updateRefs.beforeOid`, see section 2). The researched GraphQL git reference has no version field for issue mutations — [GraphQL git reference](https://docs.github.com/en/graphql/reference/git)

### Inferences
- **[inf]** Every issue-level claim (label, assignee, comment, body marker) is last-writer-wins or set-union. A "write, then read back, then arbitrate" protocol (for example, first comment wins by id or created_at) is the only way to use these writes, and it depends on read-after-write consistency, which is not guaranteed (section 3).
- **[inf]** "DELETE `agent:todo` label; the 200 response wins and the 404 response loses" might look like a CAS. GitHub does not document it as atomic. A 404 is also ambiguous: label missing from the issue, label missing from the repo, or a stale replica. Do not rely on it.
- **[inf]** Issue body edit (PATCH) takes no expected-body or version parameter, so a marker in the body is plain last-writer-wins.

### Gaps
- I did not verify Projects v2 field mutations (`updateProjectV2ItemFieldValue`) or the newer issue fields/types for a version precondition. None was found in the pages I read.
- I found no documented or observed response for two truly concurrent PATCHes to the same issue. I expect both to return 200.

## 2. Git refs as a create-if-absent / CAS primitive

### Takeaway
Git refs are the only GitHub-native atomic primitive found that does not depend on a PR. GraphQL `updateRefs` with `beforeOid` gives a documented, atomic, multi-ref compare-and-set. `beforeOid = 0000…0` gives a documented create-if-absent. REST `POST /git/refs` and `PATCH force=false` behave as create-if-absent and fast-forward-only, but the docs give only generic 409/422 meanings. The specific messages are seen in practice but not documented.

### Cited Findings
- **[doc]** GraphQL `updateRefs`: "Creates, updates and/or deletes multiple refs in a repository. All updates are performed atomically, meaning that if one of them is rejected, no other ref will be modified." "RefUpdate.beforeOid specifies that the given reference needs to point to the given value before performing any updates." A value of `0000000000000000000000000000000000000000` can verify that the ref does not exist. Used as `afterOid`, it deletes the ref. `force: true` allows non-fast-forward updates — [GraphQL git reference](https://docs.github.com/en/graphql/reference/git); same text in the German/Japanese mirrors ([de](https://docs.github.com/de/enterprise-server@3.21/graphql/reference/git))
- **[doc]** `RefUpdate` fields: `name` (GitRefname!, "fully qualified … e.g. refs/heads/branch-name"), `afterOid` (GitObjectID!), `beforeOid` (GitObjectID, optional), `force` (Boolean) — [GraphQL git reference](https://docs.github.com/en/graphql/reference/git)
- **[doc]** `createRef(name, oid, repositoryId)`: oid "Must point to a commit". `updateRef(refId, oid, force)`: `force` = "Permit updates of branch Refs that are not fast-forwards". Neither takes an expected old oid. `deleteRef(refId)` has no precondition — [GraphQL git reference](https://docs.github.com/en/graphql/reference/git)
- **[doc]** REST `POST /repos/{o}/{r}/git/refs`: `ref` must be fully qualified. "If it doesn't start with 'refs' and have at least two slashes, it will be rejected." You cannot create refs in an empty repository. Status codes: 201, 409 "Conflict", 422 "Validation failed, or the endpoint has been spammed." — [REST git refs](https://docs.github.com/en/rest/git/refs)
- **[doc]** REST `PATCH /git/refs/{ref}`: `force` default false, "Leaving this out or setting it to false will make sure you're not overwriting work." Status codes: 200/409/422. DELETE: 204/409/422 (422 includes "an attempt was made to delete the default branch") — [REST git refs](https://docs.github.com/en/rest/git/refs)
- **[obs]** Creating an existing ref returns HTTP 422 with message "Reference already exists". Seen in GitLab's GitHub importer logs — [gitlab-ce#17766](https://gitlab.com/gitlab-org/gitlab-ce/-/issues/17766)
- **[obs]** A non-fast-forward PATCH with `force:false` returns HTTP 422 "Update is not a fast forward" (sisyphos smoke test, 2026-10-10) — [matheus-ft/sisyphos#15](https://github.com/matheus-ft/sisyphos/pull/15). A common failure chain: "update branch main failed (HttpError: Update is not a fast forward), fallback to create branch … HttpError: Reference already exists" — summarised from search results citing [Ibotta/yaml-update-action#20](https://github.com/Ibotta/yaml-update-action/pull/20) and similar PRs (snippet-level, not fetched in full)
- **[obs]** Create-ref can also fail with a different, intermittent 422 "Reference update failed". The reporter suspected branch protection but did not confirm it — [rest-api-description#4887](https://github.com/github/rest-api-description/issues/4887)
- **[obs]** Pitfall: Octokit v5 appends a documentation URL to `error.message`, so a full-string comparison against "Update is not a fast forward" never matched. Match the status code plus the message prefix — search-result summary of [tyriis/multi-file-commit#11](https://github.com/tyriis/multi-file-commit/pull/11)-class PRs (not fetched in full)
- **[obs]** One client collapsed a failed `force:false` ref PATCH into "request failed or was unverifiable". It could not tell a definite rejection (422 not-fast-forward) from an unknown outcome, and that stalled its coordination — [OlyForge3D/PrintFarmer#2964](https://github.com/OlyForge3D/PrintFarmer/issues/2964) (2026-09-24)
- **[doc]** Rulesets target only branches and tags ("Restrict creations: … only users with bypass permissions can create branches or tags whose name matches the pattern"). Push rulesets apply to private/internal repos and their fork network. No rule targeting arbitrary `refs/*` namespaces is documented — [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- **[doc]** PR-specific CAS: `PUT /pulls/{n}/merge` with `sha` returns "409 Conflict if sha was provided and pull request head did not match". `PUT /pulls/{n}/update-branch` with `expected_head_sha` returns 422 on mismatch — [Pulls](https://docs.github.com/en/rest/pulls/pulls)

### Inferences
- **[inf]** The best claim primitive for "exactly one daemon owns issue N": one GraphQL `updateRefs` call with `{name: "refs/<ns>/issue-N", beforeOid: 0…0, afterOid: <claim-commit>}`. It is documented as atomic, so exactly one concurrent caller succeeds. Release or transfer is another `updateRefs` call with `beforeOid` = the current claim oid. REST `POST /git/refs` is the next best: a 201 means the claim was created. 422 "Reference already exists" means lost. Treat any other 409/422 as unknown and re-read.
- **[inf]** The claim commit can encode the owner (daemon id, time) in its message or tree, so the ref value identifies the owner. That needs `POST /git/blobs`, `/git/trees`, and `/git/commits` first, which is extra content-creating writes. A cheaper option: all daemons point the ref at one shared commit per daemon (a pre-made "owner=A" commit). The oid then names the owner, and there is one write per claim.
- **[inf]** Custom namespaces such as `refs/claims/...`: the REST validation rule ("starts with refs, two slashes") allows them syntactically, but I found no source that confirms or denies GitHub accepts them. `refs/pull/*` is GitHub-managed and almost certainly refused. Because rulesets cannot target non-branch/tag refs, a custom namespace is also not protectable by rulesets: any user with write access can delete or move it. `refs/heads/claims/issue-N` is supported for certain, but it shows up as branches in the UI. Branch rulesets (for example, "Restrict deletions") apply to it, and could also block the daemon's own release unless it has bypass permission.
- **[inf]** A lease (expiry) is not native. Expiry must be encoded in the claim commit or kept elsewhere. A takeover is a CAS from the stale owner's oid to the new owner's oid with `updateRefs`/`beforeOid`, which is safe against two concurrent takeovers.
- **[inf]** `git push --force-with-lease=<ref>:<expected>` and a plain non-force push are server-side CAS over the git protocol. A standard git receive-pack checks the old-oid in each ref update command. GitHub's equivalent atomic guarantee is documented only for GraphQL `updateRefs`.

### Gaps
- I did not test (no writes made) whether GitHub.com accepts `refs/claims/...` via REST POST, GraphQL `updateRefs`, or git push. A one-line probe against a scratch repo would settle it.
- The GraphQL error shape/message when `beforeOid` mismatches (for example, "stale info" or "reference already exists") is not documented in the pages I read.
- I found no rate or count limit on refs per `updateRefs` call, and no cap on the total number of refs per repository.

## 3. Read-after-write consistency

### Takeaway
GitHub documents no read-after-write guarantee. Third parties report that ref reads can lag a write "for a moment", and clients that honour `Cache-Control: private, max-age=60` can serve reads up to 60 s stale. Write-then-read-back arbitration (first comment wins, read-back label check) is therefore unsafe without a retry/settle window. A CAS on the write itself (refs) avoids the problem.

### Cited Findings
- **[obs]** "GitHub's branch reads can trail a write to it for a moment". After a lost race, the read "still showed the old head". The fix retries reads at 250/500/1000/2000 ms (a design bound under 4 s, not a measured lag) — [matheus-ft/sisyphos#15](https://github.com/matheus-ft/sisyphos/pull/15)
- **[obs]** GitHub API responses carry `Cache-Control: private, max-age=60`. A browser cache served a stale ref GET, so a commit was built on an old parent and the update failed with 422 — search-result summary of [woowook-pixel/gulgul-vault#6](https://github.com/woowook-pixel/gulgul-vault/pull/6) (not fetched in full)
- **[obs]** The `gh` CLI cache plus GitHub's own lag right after a POST produced stale comments. A hishel-based HTTP cache could serve data about 60 s old — [gizmo385/gh-lazy#383](https://github.com/gizmo385/gh-lazy/issues/383) (search snippet)
- **[doc]** Polling guidance: use stable parameters and sort order for more 304s. "A different page size, page number, or filter produces a different response with a different `etag`" — [Best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)

### Inferences
- **[inf]** An ETag/304 cache that sits in front of claim reads can return a pre-claim view. Claim verification reads must bypass any local conditional-request cache.
- **[inf]** "First comment wins" needs every daemon to see the same ordered comment list. With replica lag, daemon A can read only its own comment and start work, while B's earlier comment is not yet visible. Two owners result. The only safe ordering is a single atomic server-side decision (a ref CAS).
- **[inf]** The response to the write itself (201 from create-ref, a GraphQL `updateRefs` success) is authoritative and needs no read-back. That is the main practical advantage of refs.

### Gaps
- I found no official GitHub statement on replica lag, its size, or which endpoints read from replicas.

## 4. How existing tools avoid double-claiming

### Takeaway
The tools I examined avoid the problem by running a single instance (Tide), by delegating to a GitHub-side serializer (Actions concurrency groups, merge queue), or by an exclusive lock service (git-lfs locks, 409 on conflict). None I found runs several independent instances that arbitrate through issue labels or comments.

### Cited Findings
- **[doc]** Prow Tide: "a single instance with a single bot token can provide merge automation to dozens of orgs and repos". It forms disjoint merge pools per `org/repo:branch` and uses REST v3 to set statuses and merge — [Tide docs](https://docs.prow.k8s.io/docs/components/core/tide/)
- **[doc]** Actions concurrency: "at most one running job or workflow in a concurrency group at any time". With the default `queue: single`, at most one pending run, and a new pending run cancels the old one. `queue: max` allows up to 100 waiting. Groups are scoped to the repository. Runs are processed FIFO, but "ordering is not guaranteed" — [Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- **[doc]** git-lfs locking API: servers "should reject lock creations if one already exists for the given path", with `409 Conflict`, body `{lock, message: "already created lock", …}`. The spec says nothing about atomicity — [git-lfs locking spec](https://github.com/git-lfs/git-lfs/blob/main/docs/api/locking.md)
- **[doc]** PR merge with `sha` returns 409 if the head moved. Merge-bot implementations use this as an optimistic check against merging an unexpected head — [Pulls](https://docs.github.com/en/rest/pulls/pulls)

### Inferences
- **[inf]** An Actions concurrency group (for example `group: claim-issue-${{ number }}`) could act as a GitHub-hosted mutex: each daemon dispatches a workflow that creates the claim. But the workflow itself still needs an atomic write, so this adds latency without adding a primitive. Note also that a pending run is cancelled, not queued, by default.
- **[inf]** The git-lfs lock API is path-keyed and per repository, and GitHub serves LFS. A lock on a synthetic path such as `claims/issue-N` is an exclusive lock with a documented 409. I did not confirm that GitHub's LFS server implements locking with atomic semantics, or that it works on repos without LFS content. It is unverified and not recommended without a probe.

### Gaps
- I did not research bors-ng (staging/trying branches, single instance), Mergify, Prow `assign`/`lifecycle` plugins, or Renovate in this pass. From memory (unverified): all of them run as single logical instances and use labels/assignees only as status, not as a mutex.
- I found no public "Kubernetes Lease over git refs" project on GitHub.

## 5. Rate limits relevant to one claim per dispatch

### Takeaway
One claim per dispatch is far below every documented limit. The relevant risk is secondary limits on content creation (80/min, 500/h) and the advice to serialize mutative calls with about 1 s between them.

### Cited Findings
- **[doc]** Secondary limits: at most 100 concurrent requests (REST + GraphQL shared). 900 points/min for REST endpoints, 2,000 for GraphQL. 90 s CPU per 60 s. "no more than 80 content-generating requests per minute" and "no more than 500 content-generating requests per hour" — [Rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- **[doc]** Primary limits: 5,000/h for a user. A GitHub App installation gets at least 5,000/h, up to 12,500/h (non-GHEC). `GITHUB_TOKEN` gets 1,000/h per repository. Exceeding a limit returns 403 or 429. Honour `retry-after`, otherwise `x-ratelimit-reset`, otherwise wait 1 minute or more with exponential backoff — [Rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- **[doc]** "make requests serially instead of concurrently" and "wait at least one second between each request" for bulk mutative calls — [Best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- **[doc]** The 422 text "or the endpoint has been spammed" appears on the git refs endpoints, so a 422 can also mean abuse throttling, not a lost race — [REST git refs](https://docs.github.com/en/rest/git/refs)

### Inferences
- **[inf]** A claim ref costs one write (or four if each claim builds its own owner commit). The secondary limits are per credential. Daemons that share one App installation share the 80/min content budget.
- **[inf]** Because 422 is overloaded (lost race, spam throttling, ruleset refusal), a claim client should map only "Reference already exists" (create) or "Update is not a fast forward" (update) to "lost". It should treat every other 422/409/5xx/timeout as unknown, and resolve the unknown by reading the ref with caches bypassed, retrying until the read is stable.

### Gaps
- I found no documentation on whether ref creation counts as "content-generating" for the 80/min limit.
