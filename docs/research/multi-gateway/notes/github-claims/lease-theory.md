# Lease, fencing and ownership-protocol theory for work claiming over GitHub + optional Postgres

Scope: the theory and failure analysis behind a protocol where (1) the durable owner record is in GitHub, (2) an optional Postgres coordination store (advisory locks or lease rows, 10 s renew, 30 s expiry) can be down, and (3) a worker skips work whose ownership is ambiguous.

Source key (all fetched 2026-11-06):
- Kleppmann, "How to do distributed locking" (2016): https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
- Burrows, "The Chubby lock service for loosely-coupled distributed systems" (OSDI 2006): https://research.google/pubs/the-chubby-lock-service-for-loosely-coupled-distributed-systems/ (PDF: https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- ZooKeeper recipes: https://zookeeper.apache.org/doc/current/recipes.html
- etcd API: https://etcd.io/docs/v3.5/learning/api/
- Kubernetes Leases: https://kubernetes.io/docs/concepts/architecture/leases/
- client-go leaderelection: https://pkg.go.dev/k8s.io/client-go/tools/leaderelection
- Consul sessions: https://developer.hashicorp.com/consul/docs/automate/session
- Jepsen etcd 3.4.3: https://jepsen.io/analyses/etcd-3.4.3
- PostgreSQL advisory lock functions: https://www.postgresql.org/docs/current/functions-admin.html
- git push: https://git-scm.com/docs/git-push
- GitHub REST refs: https://docs.github.com/en/rest/git/refs
- GitHub REST best practices: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
- Surfing Complexity, fencing tokens in FizzBee (2025): https://surfingcomplexity.blog/2025/03/03/locks-leases-fencing-tokens-fizzbee/
- FoundationDB simulation testing: https://apple.github.io/foundationdb/testing.html

## Q1. Durable ownership vs. short-lived leases vs. liveness: how do systems separate them?

### Takeaway
Every mature system splits three things: a **liveness signal** (session/keepalive/heartbeat), a **lease** (a time-bounded right derived from liveness), and a **generation number** (a monotonic counter that names *which* acquisition is current). Only the generation number is safe to act on downstream; the lease is an efficiency device. None of these systems makes a lease the durable record of ownership; durable state is plain data guarded by compare-and-set.

### Cited Findings
- **Chubby** is built for *coarse-grained* locks: a lock might hand a primary all access to data "for a considerable time, perhaps hours or days". Coarse locks put far less load on the lock server and make brief lock-server unavailability tolerable. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Chubby separates the lock from the **session**: a session lives by KeepAlives; when the client's local lease timeout passes it is "in jeopardy", empties its cache, and waits a **grace period (45 s default)** before declaring the session lost. During jeopardy the library sends an event so the application can "quiesce". — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Chubby **sequencer**: an opaque string with the lock name, the mode, and the **lock generation number**. A holder passes it to servers; the server checks it is still valid and rejects the request if not. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- **ZooKeeper** lock and election recipes use *ephemeral sequential* znodes: the lowest sequence number holds the lock, each waiter watches only its predecessor (to avoid the herd effect), and nodes of failed members are removed when ZooKeeper detects the failure. The recipe adds a GUID to the node name because a create can succeed while its reply is lost, and on reconnect the session is still valid so the node is *not* removed — an "ambiguous" claim the client must resolve by looking for its own GUID. — [ZooKeeper recipes](https://zookeeper.apache.org/doc/current/recipes.html)
- Kleppmann: ZooKeeper's `zxid` or the znode version number can serve as a fencing token. — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- **etcd** leases detect liveness: a lease "expires if the etcd cluster does not receive a keepAlive within a given TTL period"; keys attached to it are deleted on expiry or revoke. Separately, transactions compare a key's `version`, `create_revision`, `mod_revision` or value (If/Then/Else, atomic). — [etcd API](https://etcd.io/docs/v3.5/learning/api/)
- **Kubernetes Lease** objects hold `holderIdentity`, `leaseDurationSeconds` and `renewTime`; node heartbeats are updates to `renewTime`, and leader election for controller-manager and scheduler uses the same object. — [Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/). The safe acquisition comes from the generic Kubernetes update rule: an update carrying a stale `metadata.resourceVersion` gets 409 Conflict (general Kubernetes behaviour, not stated on that page).
- **Consul sessions** tie a lock to node health checks; a session is invalidated on node deregistration, a critical health check, explicit destroy, or TTL expiry. The tuple **(Key, LockIndex, Session)** is a sequencer; `LockIndex` increments on each acquire so downstream systems can reject stale requests. Locks are advisory, and any client can release a lock (operator force-release). — [Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)
- **Postgres advisory locks** are pure liveness-bound locks: session-level locks are "held until released or the session ends", and `pg_advisory_unlock_all()` is "implicitly invoked at session end, even if the client disconnects ungracefully". `pg_try_advisory_lock` returns `false` immediately when the lock is busy. Transaction-level `xact` locks are released at transaction end with no manual release. — [PostgreSQL docs](https://www.postgresql.org/docs/current/functions-admin.html)

### Inferences
- A Postgres **advisory** lock carries no generation number, so it cannot be a fencing token; it also vanishes when a pooled connection or the server drops, with no record that it ever existed. For this design a **lease row** (`ticket_id, holder, epoch bigint, expires_at` set from the DB server's `now()`) is the better shape: it gives an epoch and survives the connection. Advisory locks fit only "don't do the same expensive thing twice right now" (efficiency).
- Map the three layers onto the target system: **durable owner** = GitHub record (assignee/label/comment marker carrying holder id + epoch); **lease** = Postgres row with 30 s expiry; **liveness** = 10 s renew. Lease expiry must *never* rewrite the durable owner; it only says "the owner is not currently live", which feeds a human or explicit reassignment path (Q4).
- The ZooKeeper "lost create reply" case transfers directly: a GitHub write that times out may or may not have applied (GitHub is not idempotent for most writes). Put a unique claim id in the written marker and re-read to resolve; until resolved, ownership is *ambiguous* and the worker skips.

### Gaps
- Kubernetes Lease docs do not describe `acquireTime`, `leaseTransitions` or `resourceVersion`; the 409 behaviour above is general Kubernetes API knowledge, not cited from a fetched page.
- The ZooKeeper recipes page does not describe session-expiry semantics in detail.

## Q2. Fencing tokens and epochs: fencing a stale worker; what if the downstream (GitHub pushes) cannot check a token?

### Takeaway
A lease alone cannot stop a paused or partitioned worker from acting after its lease expired; only the **resource** rejecting stale epochs can. GitHub issue/PR writes do not check tokens, so fencing must be built from the CAS primitives that do exist (git ref compare-and-swap, re-read-before-write against the durable record) plus delay-based mitigation (Chubby/Consul lock-delay), and residual duplicates must be made harmless.

### Cited Findings
- The canonical failure: a client pauses (e.g. GC) longer than the lease, wakes believing it still holds the lock, and writes. Checking expiry just before the write does not help, because the pause can come at any point. — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- Fix: "a fencing token is simply a number that increases" on every acquire; the storage server remembers the highest token seen and rejects lower ones. This needs the storage to take "an active role in checking tokens". Without that, safety requires "preventing client 1 from performing any operations under the lock". — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- **Efficiency vs correctness locks**: if the lock only avoids duplicate work, a simple single-node lock is fine and occasional lost locks are acceptable; if correctness depends on it, use a consensus system plus fencing. — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- Jepsen found etcd locks lost mutual exclusion even in healthy clusters with 1–3 s TTLs, and lost ~18% of acknowledged updates with 2 s TTLs and pauses; it argues "distributed locks are a fundamentally unsafe concept in asynchronous systems" and recommends using the lock key's revision as a fencing token, and using locks "for performance, not safety" unless the resource enforces safety. — [Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)
- Fencing tokens order accesses but do **not** give mutual exclusion: a model checker found that two holders can both believe they hold the lock and the *lower* token can reach the resource first, so both act. — [Surfing Complexity](https://surfingcomplexity.blog/2025/03/03/locks-leases-fencing-tokens-fizzbee/)
- Mitigation when the resource cannot check tokens — **lock-delay**: Chubby, if a lock is freed because the holder *failed or became inaccessible* (not on normal release), refuses new claims for a lock-delay up to one minute; "while imperfect, the lock-delay protects unmodified servers". Chubby's API docs say a lock-delay may be used with services that cannot check sequencers. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Consul does the same: lock-delay 0–60 s, default 15 s, after session invalidation, giving a possibly-live holder time to notice and stop. — [Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)
- client-go leader election states outright: it "does not guarantee that only one client is acting as a leader (a.k.a. fencing)", and `ReleaseOnCancel` is only safe if all guarded work finishes before cancellation. — [client-go leaderelection](https://pkg.go.dev/k8s.io/client-go/tools/leaderelection)
- **git** gives a real CAS on refs: `--force-with-lease=<ref>:<expect>` updates the ref only if its current value equals `<expect>`; an empty `<expect>` means the ref must not exist. `--atomic` updates all refs or none. — [git push](https://git-scm.com/docs/git-push)
- The GitHub REST "update a reference" endpoint takes only `sha` and `force`; with `force=false` the update must be a fast-forward. There is no expected-old-sha parameter. — [GitHub REST refs](https://docs.github.com/en/rest/git/refs)
- GitHub REST does not support conditional requests for unsafe methods "unless otherwise noted" for a specific endpoint; ETag/`If-None-Match` are documented for conditional `GET`s only. It also recommends serial mutative requests with ≥1 s spacing. — [GitHub best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)

### Inferences
- **What can be fenced on GitHub:** branch pushes. Give each claim epoch its own branch (e.g. `agent/<ticket>-e<epoch>`) or push with `--force-with-lease=<ref>:<last-sha-I-pushed>`. A stale worker's push then fails CAS (or lands on a branch nobody merges). Creating a branch with empty `<expect>` is a "create-if-absent" claim primitive that GitHub enforces server-side.
- **What cannot be fenced:** issue labels, assignees, comments, PR creation. For these, use (a) **re-read the durable owner record immediately before each irreversible step** and abort if holder/epoch differ (narrows, does not close, the window — the Kleppmann pause argument still applies); (b) **lock-delay**: after a lease expires abnormally, wait well beyond the old holder's renew deadline before anyone else acts (Chubby: up to 60 s; Consul: 15 s default); (c) **self-fencing** on the worker: stop issuing GitHub writes as soon as the worker's own renew deadline passes without a confirmed renew (Chubby's jeopardy → quiesce).
- **Make residual duplicates idempotent/detectable**: embed `claim_id`/epoch in PR bodies, branch names and comment markers so a reconciler can find and close the loser. With fencing gone, Jepsen's and Kleppmann's conclusion holds: the lock is an efficiency device; correctness comes from the downstream being safe against a second writer.
- A Postgres lease-row `epoch` is the fencing token for anything that goes *through* Postgres (e.g. `UPDATE … WHERE epoch = $mine`); it is only advisory for GitHub writes.

### Gaps
- Whether any GitHub write endpoint (GraphQL `updateRef`, `createRef`) offers a documented expected-old-value check was not confirmed; only `createRef`-fails-if-exists behaviour is implied by git semantics, not by a fetched GitHub doc. Test it before relying on it.
- No source quantified real-world GitHub write-visibility lag (read-your-writes across API replicas).

## Q3. CAP framing: two workers partitioned from each other but both reach GitHub; one worker partitioned from GitHub.

### Takeaway
GitHub is the only linearizability point both workers share, so worker-to-worker partitions are harmless *if* the claim decision is a CAS on GitHub state; but GitHub offers almost no write CAS, so two workers can both "win" a read-then-write claim. A worker cut off from GitHub (or from Postgres) cannot learn whether it still owns anything; the safe (CP) choice is to stop and skip, sacrificing availability.

### Cited Findings
- Lock services must trade correctness for liveness: a slow or unreachable process may be declared dead while it still believes it holds the lock; and even a perfect lock service cannot order a delayed message from the old holder against the new holder's. — [Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)
- Redlock-style safety holds only under a *synchronous* model (bounded network delay, process pauses and clock error). — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- A Chubby client whose lease timer expires "becomes unsure whether the master has terminated its session", disables its cache and enters jeopardy; if no KeepAlive succeeds in the grace period, the session is lost. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- GitHub write endpoints do not accept conditional (`If-Match`) requests in general. — [GitHub best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)

### Inferences
- **Case A — workers partitioned from each other, both reach GitHub (Postgres up):** Postgres lease row with `INSERT … ON CONFLICT DO NOTHING` / `UPDATE … WHERE epoch=` is the CAS; GitHub record is written *after* winning it. Safe.
- **Case A' — same, Postgres down:** both read GitHub "unowned", both write a claim marker → split brain. Options, strongest first: (1) a create-if-absent git ref as the claim (`--force-with-lease=refs/claims/<ticket>:` with empty expect), which GitHub enforces; (2) write-then-read-back tie-break: each writes a marker with a claim id, waits a settle interval, re-reads, and the deterministic winner (lowest comment id / earliest timestamp from GitHub) proceeds while others retract — safe only if reads are eventually consistent within the settle interval (unverified); (3) policy: with Postgres down, **do not claim new work at all**, only continue work already durably owned. Option (3) matches "skip when ambiguous" and is the simplest.
- **Case B — a worker partitioned from GitHub but reaching Postgres:** it can renew its lease but cannot do the work; it should keep the durable record (still owner) and let the lease state show "live but blocked". Nobody else should take over without an explicit reassignment.
- **Case C — a worker partitioned from Postgres but reaching GitHub:** it cannot prove liveness; others will see its lease expire. It must self-fence (stop GitHub writes after its renew deadline), because others cannot fence its GitHub writes. Its *durable* ownership still stands (Q4), so others treat the ticket as "reserved, owner offline" and skip it — no duplicate, only delay.
- **Case D — partitioned from both:** owner keeps durable ownership; on recovery it must re-read GitHub before resuming, since a human may have reassigned the ticket.
- Net: with durable ownership that never auto-expires, the only ways to get duplicates are (i) the initial claim race when Postgres is down and (ii) explicit reassignment while the old owner is still running. Both are closed by the rules above (no new claims without the CAS store or a git-ref CAS; reassignment waits for self-fence + lock-delay and bumps the epoch).

### Gaps
- No primary source found on GitHub's read-after-write consistency guarantees for issue labels/comments across API replicas; option (2) above depends on it.

## Q4. Patterns for "reserved while owner offline; explicit reassignment only" and human-authorized transfer

### Takeaway
The established systems all expire ownership automatically, so "never auto-expire" is a deliberate deviation, closest to Chubby's coarse-grained, hours-to-days locks plus Consul's operator force-release. The pattern is: lease expiry changes *liveness status*, never *ownership*; transfer is an explicit, epoch-bumping CAS performed by a human or an authorized actor, preceded by a fence-or-wait step.

### Cited Findings
- Chubby is designed for locks held "hours or days", where the lock owner's identity matters more than fast failover. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Chubby applies lock-delay only when the lock frees because the holder *failed or became inaccessible*; a normal release is immediately available. It caps lock-delay at one minute so a faulty client cannot make a resource unavailable for arbitrarily long. — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Consul: "any client can release a lock", which lets operators force-terminate sessions; the `release` behaviour increments `ModifyIndex` and, on re-acquire, `LockIndex`. — [Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)
- Kubernetes keeps a `holderIdentity` on the Lease; a new API server instance with the same hostname "takes over the existing lease under a new holderIdentity". Expired leases of API servers that no longer exist are garbage collected after one hour. — [Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/)
- Kubernetes is moving toward *explicit release on exit* (alpha `ControllerManagerReleaseLeaderElectionLockOnExit`) instead of waiting for TTL expiry. — [Kubernetes Leases](https://kubernetes.io/docs/concepts/architecture/leases/)

### Inferences
- **State machine (suggested):** `unowned → owned(holder, epoch)` via CAS. Liveness overlay from Postgres: `live | stale | unknown(store down)`. Allowed transitions from `owned`: holder release (`→ unowned`, epoch kept), and **reassign(new_holder, actor, reason)** (`→ owned(new, epoch+1)`), never time-based.
- **Reassignment protocol:** (1) actor requests transfer; (2) if old holder is `live`, send a stop/handoff request and wait for its release (cooperative transfer); (3) if `stale`/`unknown`, wait ≥ old holder's self-fence deadline + lock-delay (cf. Chubby's 60 s cap, Consul's 15 s default) — or require the human to confirm the old worker is dead; (4) write the new durable record with `epoch+1` and an audit entry (actor, reason); (5) new holder works on epoch-scoped branches so the old holder's late pushes cannot overwrite (Q2).
- **Old-owner return:** on reconnect, every worker re-reads the durable record before any write; a mismatch in holder/epoch means "you were fenced", so it stops and leaves its branch for a reconciler.
- "Durable reserved while offline" deliberately trades availability for no duplicates, which is the posture the requirements ask for; the operational cost is a queue of orphaned tickets, so a visible "owner offline since T" signal (Kubernetes-style `renewTime`) is needed for humans to act on.

### Gaps
- No primary source describes a production system with *non-expiring* durable ownership plus human-only transfer; the pattern above is inferred from Chubby coarse locks and Consul operator release.

## Q5. Clock-skew-safe lease designs

### Takeaway
Never compare timestamps produced by different machines. Either measure lease age on the observer's own **monotonic** clock from the moment it saw a change (client-go), or let the **single authority** (Postgres server `now()`, Chubby master) own expiry while holders use a conservative, shorter local deadline.

### Cited Findings
- client-go: "A client only acts on timestamps captured locally to infer the state of the leader election"; it is "tolerant to arbitrary clock skew, but is not tolerant to arbitrary clock skew rate". Defaults for core clients: LeaseDuration 15 s, RenewDeadline 10 s, RetryPeriod 2 s. — [client-go leaderelection](https://pkg.go.dev/k8s.io/client-go/tools/leaderelection)
- Chubby: the client keeps a local lease timeout that is a *conservative* approximation of the master's, assuming worst-case reply flight time and requiring "that the server's clock advance no faster than a known constant factor faster than the client's". — [Chubby paper](https://storage.googleapis.com/gweb-research2023-media/pubtools/4444.pdf)
- Consul TTL is a lower bound: Consul "will not expire the session before the TTL is reached, but it is allowed to delay the expiration past the TTL"; docs advise conservative TTLs and renewing early for network delay and clock skew. — [Consul sessions](https://developer.hashicorp.com/consul/docs/automate/session)
- Redlock depends on bounded clock error; clock jumps can let two clients hold the lock. — [Kleppmann](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- Jepsen's etcd suite injected clock skew of hundreds of seconds and millisecond-scale strobing. — [Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)

### Inferences
- For a Postgres lease row: set and test `expires_at` only with the DB's `now()` inside the SQL statement (`UPDATE … SET expires_at = now() + '30 s' WHERE holder=$me AND epoch=$e AND expires_at > now()`), so only one clock decides expiry.
- The holder self-fences on its **own monotonic clock** measured from *when it sent* the last successful renew (not when the reply arrived), with a deadline shorter than 30 s (e.g. 20 s), so its belief always expires before the server's. 10 s renew / 30 s expiry gives two missed renews of slack, close to client-go's 10/15 ratio and more conservative.
- Takeover (for leases, not durable ownership) must additionally wait a lock-delay beyond expiry to cover pauses that the monotonic clock cannot see.
- Never use GitHub `updated_at` timestamps to judge liveness against a local clock; if GitHub time is used at all, compare GitHub times only to other GitHub times.

### Gaps
- Gray & Cheriton (1989), the original lease paper, was not fetched; its clock-drift bound argument is the classical source and should be cited if the report needs it.

## Q6. Testing: deterministic simulation, Jepsen-style partition tests, model checking (TLA+) of claim protocols

### Takeaway
Use three layers: a small model (TLA+/FizzBee) of the claim/reassign state machine to find interleavings; a deterministic simulation of the real code with injected faults and controlled time; and a Jepsen-style history checker over a fault-injected run against fake GitHub and a real Postgres.

### Cited Findings
- FoundationDB runs "an entire FoundationDB cluster within a single-threaded process" with simulated time, giving "perfect repeatability", and injects network clogging/delays, machine reboots and "coming back from the dead", and disk faults; tens of thousands of simulations run nightly. — [FoundationDB testing](https://apple.github.io/foundationdb/testing.html)
- Jepsen's etcd lock tests: randomized lock/unlock with keepalive-held leases, checked for linearizability with Knossos; a lock-guarded set-update test checked for lost updates; faults were partitions (including non-transitive), crashes, pauses and clock skew. — [Jepsen etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3)
- A FizzBee model of locks+leases+fencing found a MutualExclusion violation even with fencing tokens — the kind of counterexample a model checker finds cheaply. — [Surfing Complexity](https://surfingcomplexity.blog/2025/03/03/locks-leases-fencing-tokens-fizzbee/)
- A TLA+ write-up models lock expiry as an action that can fire at any time (equivalent to an arbitrarily long client pause) and notes the pitfall that TLC does not check a `THEOREM`; the invariant must be listed as an `INVARIANT` in the config. — [Terzian, Modelling distributed locking in TLA+](https://medium.com/@polyglot_factotum/modelling-distributed-locking-in-tla-8a75dc441c5a) (via search summary; page not fetched in full)
- T-Lease models a lease protocol in TLA+ with TLC on a finite instance and notes that the holder's countdown must start when it *sends* the request, so the holder's lease can expire before the grant arrives. — [T-Lease, arXiv 2101.06485](https://arxiv.org/pdf/2101.06485) (via search summary)

### Inferences
- **Model (sketch, not a sourced spec):** variables `durable[t] ∈ {None} ∪ (Worker × Nat)`, `lease[t]`, `believes[w][t] ∈ Nat∪{0}`, `pgUp ∈ BOOLEAN`, `ghWrites` (set of (worker, epoch, kind)). Actions: `Claim(w,t)` (CAS on Postgres when `pgUp`, else either disabled or a read-then-write race on `durable` to compare designs), `Renew`, `LeaseExpire` (any time), `SelfFence(w)`, `Pause/Resume(w)`, `Reassign(t, w2)` (human; sets epoch+1), `PgDown/PgUp`, `GhWrite(w,t)` enabled when `believes[w][t] > 0`. Invariants: **NoDuplicateUnfencedWrite** — no two different epochs both perform a non-fenceable write (`kind ∈ {pr_open, label, comment}`) for the same ticket after the higher epoch exists; **DurableNeverAutoExpires** — `durable[t]` changes only via `Claim` from None, `Release`, or `Reassign`; **FencedPushes** — every accepted push to an epoch branch has the branch's epoch. Expect TLC to show NoDuplicateUnfencedWrite fails unless Reassign waits for SelfFence/lock-delay — that is the point of the model.
- **Simulation:** run workers against an in-memory fake GitHub (with injectable latency, lost replies after apply, 5xx, secondary-rate-limit 403s) and a fake or real Postgres with injected disconnects; drive time with a virtual clock and seeds. Check: no ticket ever has two live PRs/branches from different epochs that were both written after the reassign.
- **Partition tests:** iptables/toxiproxy between workers and Postgres and between workers and the fake GitHub; SIGSTOP workers past 30 s (the GC-pause case); skew wall clocks; then check histories for duplicate claims and for writes after a worker's self-fence deadline.
- The "lost reply after apply" fault is the most important GitHub-specific injection: it creates the ambiguous-claim state the protocol must skip rather than retry blindly.

### Gaps
- The Terzian TLA+ article and T-Lease paper were seen only via search summaries; no ready-made TLA+ spec of a claim protocol with external non-fenceable writes was found.
- No public Jepsen analysis of Postgres advisory locks or of GitHub-as-coordinator was found.
