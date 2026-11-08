# Claim GitHub issues through atomic git refs

Several independent daemons that share one GitHub repository can get at-most-one ownership
only if the claim decision is a single server-side compare-and-set, and on GitHub **the only
documented general-purpose compare-and-set is a git ref**: GraphQL `updateRefs` with a
`beforeOid` precondition is documented as atomic, and `beforeOid` set to forty zeros is a
documented create-if-absent. Every issue-level write (labels, assignees, comments, body) is
last-writer-wins or set-union with no precondition, so two daemons that "claim" through them
both receive success. GitHub also documents no read-after-write guarantee, and third parties
observe reads that trail writes, so write-then-read-back arbitration is unsafe. The protocol
that follows from this has three layers: a durable owner record that is a git ref (with an
optional issue label as a human-readable mirror), a Postgres lease row that reports liveness
only and never rewrites ownership, and an epoch number that names the current acquisition
and scopes every fenceable write. A stale owner cannot be fenced on issue writes at all, so
safety for those comes from self-fencing, a lock-delay before reassignment, and idempotent,
claim-id-tagged side effects. Any write whose outcome is unknown (timeout, overloaded 422,
5xx) leaves the ticket **ambiguous**, and an ambiguous ticket is skipped until a cache-bypassing
read resolves it. Test the protocol with a small model check, a deterministic simulation that
injects "reply lost after apply", and a live probe against a scratch repository that pins the
exact error responses the client maps to "lost".

Labels used below: **[documented]** is a guarantee stated in vendor or primary documentation,
**[observed]** is behaviour reported by third parties in public issues or pull requests, and
**[inference]** is this report's reasoning from those facts.

## Issue writes never arbitrate; only a ref write does

GitHub's REST guidance states that "conditional requests for unsafe methods, such as `POST`,
`PUT`, `PATCH`, and `DELETE` are not supported" unless an endpoint documents otherwise; ETags
and `If-None-Match` are described for reads only **[documented]**
([REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)).
The issue endpoints add no exception. Adding labels is additive ("the labels to add to the
issue's existing labels"), setting labels replaces them, and neither takes a version or
expected value **[documented]** ([Labels](https://docs.github.com/en/rest/issues/labels)).
Adding assignees adds up to ten, never replaces an existing assignee, silently ignores users
without push access, and documents only `201` **[documented]**
([Assignees](https://docs.github.com/en/rest/issues/assignees)). The consequence is direct:
**two daemons that both add `agent:claimed` or both self-assign both succeed** **[inference]**.

A tempting shortcut is "DELETE the `todo` label; whoever gets `200` wins, whoever gets `404`
loses". GitHub documents that the endpoint returns `404` when the label does not exist, but
does not say whether a label that exists in the repository but not on the issue also returns
`404`, and does not describe the delete as atomic across callers **[documented]**
([Labels](https://docs.github.com/en/rest/issues/labels)). A `404` therefore conflates three
causes (label absent from the issue, absent from the repository, or a stale replica), and the
shortcut must not carry correctness **[inference]**. Issue body edits likewise take no expected
body, so a body marker is plain last-writer-wins **[inference]**.

Refs are different. GraphQL `updateRefs` "creates, updates and/or deletes multiple refs in a
repository. All updates are performed atomically, meaning that if one of them is rejected, no
other ref will be modified", and `RefUpdate.beforeOid` "specifies that the given reference
needs to point to the given value before performing any updates"; a `beforeOid` of
`0000000000000000000000000000000000000000` verifies that the ref does not exist, the same value
as `afterOid` deletes it, and `force: true` permits non-fast-forward moves **[documented]**
([GraphQL git reference](https://docs.github.com/en/graphql/reference/git)). The older
`createRef`, `updateRef` and `deleteRef` mutations take no expected old value **[documented]**
(same source), so `updateRefs` is the one to use. Over the git protocol,
`git push --force-with-lease=<ref>:<expect>` updates only if the ref equals `<expect>`, an empty
`<expect>` requires that the ref not exist, and `--atomic` applies all ref updates or none
**[documented]** ([git push](https://git-scm.com/docs/git-push)).

| Primitive | Precondition | Success | Documented failure | Observed failure text |
|-----------|--------------|---------|--------------------|-----------------------|
| GraphQL `updateRefs` | `beforeOid` (zeros = must not exist) | mutation returns | "rejected", no other ref modified | not found in sources |
| REST `POST /git/refs` | implicit: ref must not exist | `201` | `409` Conflict; `422` "Validation failed, or the endpoint has been spammed" | `422` "Reference already exists" |
| REST `PATCH /git/refs/{ref}`, `force=false` | implicit: fast-forward only | `200` | `409`; `422` | `422` "Update is not a fast forward" |
| `git push --force-with-lease=ref:expect` | explicit expected oid | push accepted | ref update rejected | not researched |
| REST `PUT /pulls/{n}/merge` with `sha` | head equals `sha` | merged | `409` if head moved | n/a |
| REST `PUT /pulls/{n}/update-branch` with `expected_head_sha` | head equals sha | accepted | `422` on mismatch | n/a |
| Labels, assignees, comments, issue body | none | `200`/`201` | none for races | both callers succeed |

The REST ref rows rest on these sources: create requires a fully qualified name that starts
with `refs` and has at least two slashes, fails in an empty repository, and documents only the
generic `201`/`409`/`422` meanings; `PATCH` with `force` false "will make sure you're not
overwriting work" **[documented]** ([REST git refs](https://docs.github.com/en/rest/git/refs)).
The specific message "Reference already exists" appears with `422` in a GitHub importer's
logs **[observed]** ([gitlab-ce#17766](https://gitlab.com/gitlab-org/gitlab-ce/-/issues/17766)),
and "Update is not a fast forward" with `422` appears in a 2026 smoke test **[observed]**
([sisyphos#15](https://github.com/matheus-ft/sisyphos/pull/15)). The two pull-request rows are
documented compare-and-sets but only guard PR merges and branch updates, not issue ownership
**[documented]** ([Pulls](https://docs.github.com/en/rest/pulls/pulls)). One of the notes for
this report doubted that GitHub exposed any expected-old-value write; the GraphQL reference
above settles that `updateRefs` does.

## The error code alone cannot tell "lost" from "unknown"

The overloaded `422` is the main hazard in a ref-based client. The REST docs give it two
meanings on the same endpoint, validation failure and "the endpoint has been spammed"
**[documented]** ([REST git refs](https://docs.github.com/en/rest/git/refs)). Create-ref has
also failed with an intermittent `422` "Reference update failed" whose cause the reporter
suspected was branch protection but never confirmed **[observed]**
([rest-api-description#4887](https://github.com/github/rest-api-description/issues/4887)).
Octokit v5 appends a documentation URL to `error.message`, so a full-string comparison against
"Update is not a fast forward" never matched; clients must match the status plus a message
prefix **[observed]** ([multi-file-commit#11](https://github.com/tyriis/multi-file-commit/pull/11),
seen via a search summary). One coordination client collapsed a failed `force:false` ref
`PATCH` into "request failed or was unverifiable", could not distinguish a definite rejection
from an unknown outcome, and stalled **[observed]**
([PrintFarmer#2964](https://github.com/OlyForge3D/PrintFarmer/issues/2964)). The error shape
`updateRefs` returns on a `beforeOid` mismatch is not documented in the pages read; it must be
pinned by a live probe before the client maps it **[inference]**.

The safe classification therefore has three outcomes, not two **[inference]**. A `201` from
create, or a successful `updateRefs` payload, is **won**, and the write response is
authoritative without a read-back. `422` with message prefix "Reference already exists"
(create) or "Update is not a fast forward" (update), plus whatever probe-pinned message
`updateRefs` returns on mismatch, is **lost**. Everything else (other `409`/`422` text, `403`
or `429` rate limiting, `5xx`, timeouts, connection resets) is **unknown**. ZooKeeper's lock
recipe meets the same problem: a create can succeed while its reply is lost, so the recipe
embeds a GUID in the node name and the client resolves the ambiguity by looking for its own
GUID **[documented]** ([ZooKeeper recipes](https://zookeeper.apache.org/doc/current/recipes.html)).
The GitHub analogue is to point the claim ref at a commit that names the claimant, then resolve
an unknown outcome by reading the ref and comparing its oid with the claimant's own
**[inference]**.

That resolving read must bypass every cache. GitHub publishes no read-after-write guarantee
**[inference, from absence in the docs read]**. A third party reports that "GitHub's branch reads
can trail a write to it for a moment" and that after a lost race the read "still showed the old
head"; its fix retries at 250, 500, 1000 and 2000 ms, which is a design bound under four
seconds, not a measured lag **[observed]**
([sisyphos#15](https://github.com/matheus-ft/sisyphos/pull/15)). API responses carry
`Cache-Control: private, max-age=60`, and a client cache that honoured it served a stale ref
read, so a commit was built on an old parent **[observed]**
([gulgul-vault#6](https://github.com/woowook-pixel/gulgul-vault/pull/6), via search summary).
An ETag cache in front of claim reads can return the pre-claim view, so resolution reads go
direct, repeat until two consecutive reads agree, and leave the ticket ambiguous (skipped) if
they never do **[inference]**.

## Ownership is a ref; the lease only reports liveness

Mature coordination systems separate three things: a liveness signal, a time-bounded lease
derived from it, and a monotonic generation number that names the current acquisition. Chubby
separates a session kept alive by KeepAlives from the lock itself, gives a client whose local
lease lapses a 45 s grace period in "jeopardy" during which the application should quiesce, and
hands holders a **sequencer** containing the lock generation number that servers check
**[documented]** ([Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)).
Consul's (Key, LockIndex, Session) tuple is a sequencer whose `LockIndex` increments on each
acquire **[documented]** ([Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)).
etcd separates TTL leases from transactions that compare a key's version or revisions
atomically **[documented]** ([etcd API](https://etcd.io/docs/v3.5/learning/api/)). Kubernetes
Lease objects hold `holderIdentity`, `leaseDurationSeconds` and `renewTime` **[documented]**
([Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/)).

All of those systems expire ownership automatically. A design where ownership stays durable on
GitHub while Postgres is down deliberately does not, which puts it closest to Chubby's
coarse-grained locks held "for a considerable time, perhaps hours or days" plus Consul's
operator force-release, where "any client can release a lock" **[documented]**
([Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf);
[Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)). No source
describes a production system with non-expiring durable ownership and human-only transfer; the
mapping below is this report's synthesis **[inference]**.

| Layer | Where it lives | What changes it | What it may never do |
|-------|----------------|-----------------|----------------------|
| Durable owner `(holder, epoch)` | git ref `claims/issue-N` pointing at an owner commit | claim from absent, holder release, explicit reassign | change because a lease expired |
| Lease | Postgres row `ticket_id, holder, epoch, expires_at` | renew every 10 s, expiry at 30 s by DB `now()` | rewrite the durable owner |
| Liveness view | derived: `live`, `stale`, `unknown` (store down) | lease state | authorize a takeover alone |
| Mirror | issue label or assignee | written after the ref claim wins | decide ownership |

Postgres advisory locks fit poorly as the lease. A session lock is "held until released or the
session ends", and `pg_advisory_unlock_all()` runs at session end "even if the client
disconnects ungracefully"; `pg_try_advisory_lock` returns false at once when busy
**[documented]** ([PostgreSQL admin functions](https://www.postgresql.org/docs/current/functions-admin.html)).
That gives no generation number and no trace once a pooled connection drops, so a lease row
with an `epoch` column is the better shape, and advisory locks suit only "don't start the same
expensive step twice right now" **[inference]**.

The claim ref name needs care. The REST validation rule ("starts with `refs`, at least two
slashes") admits a custom namespace such as `refs/claims/issue-N` syntactically, but no source
confirms GitHub.com accepts writes there **[inference]**. Rulesets target only branches and tags,
so a custom namespace could not be protected and any writer could move or delete it
**[documented]** ([Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)).
`refs/heads/claims/issue-N` certainly works but appears as a branch in the UI, and a branch
deletion rule would block the daemon's own release unless it holds bypass permission
**[inference]**. A one-line probe against a scratch repository settles which namespace to use.
To keep the claim to one write, each daemon can pre-create one "owner = daemon X" commit and
point claim refs at it, so the oid names the owner; encoding the epoch needs a per-claim
commit, which costs blob, tree and commit writes first **[inference]**.

### The claim protocol

The protocol below combines the primitives and theory **[inference]**. To **claim** issue N, a
daemon first reads the claim ref directly. If it exists, the ticket is owned and the daemon
skips it. If Postgres is up, the daemon wins the lease row (`INSERT … ON CONFLICT DO NOTHING`,
epoch from the row), then issues `updateRefs` with `beforeOid` zero and `afterOid` its owner
commit. If Postgres is down, the ref create-if-absent alone is still a correct claim, because
GitHub enforces it; the design choice is whether to allow new claims at all in that state. The
conservative policy, "while the store is down, continue durably owned work but claim nothing
new", matches the skip-when-ambiguous goal and costs only throughput. Only after the ref
write returns **won** does the daemon write the label or assignee mirror. On **unknown**, the
ticket is ambiguous: the daemon does no work, resolves by cache-bypassing reads of the ref, and
proceeds only if the ref points at its own commit.

**Release** is `updateRefs` from the current oid to zero. **Reassignment** is the only other
transition and is never time-based: an authorized actor requests it; if the old holder is
`live` the actor asks it to release and waits; if it is `stale` or `unknown` the actor waits
beyond the old holder's self-fence deadline plus a lock-delay, or a human confirms the old
process is dead; then one `updateRefs` moves the ref from the old oid to the new holder's commit
with epoch plus one and an audit record of actor and reason. Because the move carries
`beforeOid`, two concurrent reassignments cannot both succeed.

**Skip rules** follow from the same states: skip if the ref names another holder; skip if any
claim write for the ticket is unresolved; skip if the ref and the label mirror disagree until a
reconciler repairs the mirror from the ref; and skip if GitHub is unreachable, since a daemon
that cannot read the ref cannot know whether it owns anything.

## Stale owners are fenced only where GitHub checks a value

A lease cannot stop a paused or partitioned worker that wakes believing it still holds the
lock; checking expiry just before the write does not help because the pause can fall between
the check and the write, and safety requires that the storage "take an active role in checking
tokens" **[documented]** ([Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)).
Jepsen found etcd locks lost mutual exclusion with 1 to 3 s TTLs even in healthy clusters,
lost about 18% of acknowledged updates with 2 s TTLs under pauses, and recommends locks "for
performance, not safety" unless the resource enforces safety **[observed]**
([Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)). client-go's leader election says
outright that it "does not guarantee that only one client is acting as a leader (a.k.a.
fencing)" **[documented]** ([client-go leaderelection](https://pkg.go.dev/k8s.io/client-go/tools/leaderelection)).
Fencing tokens also do not by themselves give mutual exclusion: a model check found that the
lower token can reach the resource first, so both holders act **[observed]**
([Surfing Complexity](https://surfingcomplexity.blog/2025/03/03/locks-leases-fencing-tokens-fizzbee/)).

On GitHub this divides writes into two classes **[inference]**. **Fenceable** writes are ref
writes: put the epoch in the work branch name (`agent/issue-N-e7`) or push with
`--force-with-lease` against the last oid this holder pushed, and a stale holder's late push
either fails the compare or lands on a branch no one merges; merges themselves can carry the
documented `sha` precondition. **Unfenceable** writes are labels, assignees, comments, issue
bodies and pull-request creation. For those, three mitigations narrow the window without
closing it. First, re-read the durable ref directly before each irreversible step and stop on
a holder or epoch mismatch. Second, self-fence: the holder stops all GitHub writes once its own
monotonic clock, measured from when it *sent* its last successful renew, passes a deadline
shorter than the server's 30 s expiry (20 s gives margin). Third, apply a lock-delay before
reassignment: Chubby refuses new claims for up to one minute after a holder fails rather than
releases, and Consul defaults to 15 s within a 0 to 60 s range **[documented]**
([Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf);
[Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)). Residual
duplicates must then be harmless and findable: tag pull-request bodies, comments and branch
names with the claim id and epoch so a reconciler can close the loser **[inference]**.

Clock handling follows client-go and Chubby. client-go acts only "on timestamps captured
locally", tolerating arbitrary skew but not arbitrary skew rate, with defaults of 15 s lease,
10 s renew deadline and 2 s retry **[documented]**
([client-go leaderelection](https://pkg.go.dev/k8s.io/client-go/tools/leaderelection)). Chubby
keeps a conservative local lease timeout assuming a bounded clock-rate difference
**[documented]** ([Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)).
So the Postgres server alone sets and tests `expires_at` with its own `now()` inside the
statement (`UPDATE … SET expires_at = now() + interval '30 s' WHERE holder = $me AND epoch = $e
AND expires_at > now()`), holders judge their own lease only by local monotonic time, and no
daemon compares a GitHub `updated_at` against its local clock **[inference]**.

### Partition cases

| Case | Postgres | Outcome under this protocol **[inference]** |
|------|----------|---------------------------------------------|
| Daemons cut off from each other, both reach GitHub | up | Lease row and ref both arbitrate; safe |
| Same | down | Ref create-if-absent arbitrates; safe if claims are allowed, otherwise no new claims |
| Owner cut off from GitHub, reaches Postgres | up | Renews lease, cannot work; stays owner; others skip |
| Owner cut off from Postgres, reaches GitHub | n/a | Lease expires for others; owner self-fences; ticket reads as "owner offline", others skip |
| Owner cut off from both | n/a | Durable ownership stands; on recovery re-read the ref before any write |
| Reassignment while old owner still runs | any | Fenced on branches; unfenceable writes rely on self-fence plus lock-delay |

With ownership that never auto-expires and claims gated on a ref compare-and-set, the remaining
paths to two simultaneous workers are an explicit reassignment that skipped the wait, and an
old owner whose pause outlasted both its self-fence deadline and the lock-delay; Kleppmann's
argument shows the second cannot be eliminated without resource-side checks, only made rare
and detectable **[inference]**.

## Existing tools sidestep the problem rather than solve it

None of the tools examined runs several independent instances that arbitrate through issue
state. Prow's Tide runs as "a single instance with a single bot token" across many orgs and
repositories **[documented]** ([Tide](https://docs.prow.k8s.io/docs/components/core/tide/)).
GitHub Actions concurrency allows "at most one running job or workflow in a concurrency group",
but by default a new pending run cancels the older pending one and ordering "is not guaranteed"
**[documented]** ([Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)).
A concurrency group could serialize claim workflows, but the workflow still needs an atomic
write inside it, so it adds latency without adding a primitive **[inference]**. The git-lfs
locking spec asks servers to reject a duplicate lock with `409` and "already created lock" but
says nothing about atomicity **[documented]**
([git-lfs locking spec](https://github.com/git-lfs/git-lfs/blob/main/docs/api/locking.md)), and
whether GitHub's LFS server implements it atomically on repositories without LFS content is
unverified, so it is not recommended without a probe **[inference]**. Bors, Mergify, Renovate
and Prow's assign plugins were not researched.

Rate limits do not constrain one claim per dispatch. Secondary limits allow 100 concurrent
requests, 900 REST points or 2,000 GraphQL points per minute, and "no more than 80
content-generating requests per minute" and 500 per hour; primary limits are 5,000 per hour for
a user and 5,000 to 12,500 for an App installation; exceeding them returns `403` or `429`, and
clients should honour `retry-after`, then `x-ratelimit-reset`, then back off at least a minute
**[documented]** ([REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)).
GitHub also advises serial mutative requests at least one second apart **[documented]**
([REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)).
Daemons that share one App installation share its content budget, and whether ref creation
counts as content-generating is undocumented **[inference]**. A rate-limit response to a claim
write is **unknown**, never **lost**.

## Three test layers catch what each other miss

The protocol needs a model check, a deterministic simulation and a live probe, because each
finds a different class of fault **[inference]**. FoundationDB runs a whole cluster in one
single-threaded process with simulated time for "perfect repeatability", injecting network
clogging, reboots and machines "coming back from the dead" across tens of thousands of nightly
runs **[documented]** ([FoundationDB testing](https://apple.github.io/foundationdb/testing.html)).
Jepsen tested etcd locks with randomized lock and unlock under keepalive leases, checked
histories for linearizability and lost updates, and injected partitions (including
non-transitive ones), crashes, pauses and clock skew of hundreds of seconds **[documented]**
([Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)). A FizzBee model found a mutual
exclusion violation that survived fencing tokens, the kind of counterexample a model checker
finds cheaply **[observed]**
([Surfing Complexity](https://surfingcomplexity.blog/2025/03/03/locks-leases-fencing-tokens-fizzbee/)).
A TLA+ lease model notes the holder's countdown must start when it sends the request
**[documented]** ([T-Lease, arXiv 2101.06485](https://arxiv.org/pdf/2101.06485), via search
summary).

The **model** (TLA+ or FizzBee) needs per-ticket `durable` (absent or holder and epoch),
`lease`, per-worker beliefs, a `pgUp` flag and a set of performed GitHub writes tagged by kind
and epoch, with actions for claim, renew, lease expiry at any time, self-fence, pause and
resume, reassign, and store down and up **[inference]**. Its invariants are
`NoDuplicateUnfencedWrite` (no two epochs both perform a label, comment or PR write after the
higher epoch exists), `DurableNeverAutoExpires` (durable owner changes only by claim from
absent, release or reassign) and `FencedPushes` (every accepted push to an epoch branch matches
that branch's epoch). Expect the first invariant to fail unless reassignment waits for
self-fence plus lock-delay; finding that counterexample is the point. List invariants as
`INVARIANT` in the TLC configuration, since TLC does not check a `THEOREM` **[documented]**
([Terzian, TLA+ locking](https://medium.com/@polyglot_factotum/modelling-distributed-locking-in-tla-8a75dc441c5a),
via search summary).

The **simulation** runs real daemon code against an in-memory fake GitHub with a virtual clock
and seeds **[inference]**. The fake must implement ref compare-and-set faithfully and inject the
faults that matter: **reply lost after the write applied** (the single most important
injection, because it creates the ambiguous state), reads that lag writes by up to a few
seconds, a stale 60 s client cache, `422` with each observed message and with the "spammed"
meaning, `5xx`, and `403`/`429` with `retry-after`. Postgres runs real or faked with injected
disconnects. The checker asserts that no ticket ever has work-side writes from two epochs after
the higher epoch exists, that no daemon starts work on an ambiguous ticket, and that every
unknown outcome eventually resolves to won or lost. Partition tests then repeat against real
processes: block traffic between daemons and Postgres or the fake GitHub, stop a daemon with
`SIGSTOP` for longer than 30 s to emulate a GC pause, skew wall clocks, and check histories for
duplicate claims and for writes after a daemon's self-fence deadline.

The **live probe** runs once against a scratch repository and pins facts no document gives
**[inference]**: whether `refs/claims/...` is writable through REST, GraphQL and git push; the
exact `updateRefs` error for a `beforeOid` mismatch and for create over an existing ref; the
current text of the REST `422` messages; and how long a direct read of a just-written ref lags.
Record the responses as fixtures for the fake, so the simulation's error mapping and
GitHub's actual behaviour cannot drift apart silently.

## Conclusion

The research reframes the question. "Which GitHub field should hold the claim" has no good
answer among issue fields; the useful question is which write GitHub will refuse, and the answer
is a ref with a stated expected value. That makes the claim correct without Postgres, which turns
the coordination store into an availability and liveness aid rather than a safety dependency, and
lets a daemon keep durable ownership through a store outage for free. The cost moves to the
error path: a client that treats every `422` as "lost" or every timeout as "failed" reintroduces
exactly the double ownership the ref was meant to prevent, so the three-way won, lost, unknown
classification and the skip-until-resolved rule are the load-bearing parts of the protocol.

Two limits remain. Issue-level side effects can never be fenced, so the guarantee for them is
"rare and detectable", not "impossible", and the reconciler that closes duplicate work tagged by
claim id is part of the design, not an afterthought. And four facts the protocol depends on
(custom ref namespace acceptance, the `updateRefs` mismatch error, current `422` texts, and
observed read lag) are undocumented, so the scratch-repository probe should run before any code
relies on them.
