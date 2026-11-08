# Ordering and merge mechanisms for replicated priority state under clock skew

Scope: a small replicated store of shared priority records (project, feature or ticket order; overrides; pause flags). Humans edit it from a dashboard and automated agents edit it, on 2 to 10 machines. Edits can happen offline. Applying a remote change must never republish it as a new change.

## Hybrid logical clocks: algorithm, bounds, drift, tie-breaking; compared with Lamport, vector and version vectors

### Takeaway
An HLC is a pair (l, c). `l` tracks the largest physical time seen. `c` is a counter that breaks ties inside one `l` value. The HLC gives Lamport's happened-before guarantee, and `l` never moves more than the clock-sync error ε from local physical time. The paper's own design guards against bad clocks: it ignores messages that would push `l` too far past `pt`, and it resets to physical time when its bounds are broken. HLC does not detect concurrency. Use version vectors or dotted version vectors to tell "concurrent" apart from "newer".

### Cited Findings
- HLC update rules, verbatim from the paper. Send or local event: `l' := l; l := max(l', pt); if l = l' then c := c+1 else c := 0`. Receive message m: `l := max(l', l.m, pt)`; `if l = l' = l.m then c := max(c, c.m)+1; elif l = l' then c := c+1; elif l = l.m then c := c.m+1; else c := 0`. Timestamps compare lexicographically on (l, c). — [Kulkarni et al., "Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases" (tech report 2014-04)](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- The guarantees, from the same paper. Theorem 1: e hb f ⇒ (l.e, c.e) < (l.f, c.f). Theorem 2: l.f ≥ pt.f. Corollary 1: |l.f − pt.f| ≤ ε, where ε is the clock-sync uncertainty. Corollary 3: c.f ≤ N·(ε+1). Under a minimum message delay d, Corollary 4 gives c.f ≤ ε/d + 1. — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- The paper says HLC "fits in to 64 bits NTP timestamp format", is "backwards compatible with NTP", and "only reads the physical clock but does not update it". — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- How to choose the drift bound, from the paper. "We set a very conservative value, ∆, on the l − pt bound. The bound ∆ can be set to a constant factor of ε, and even on the order of seconds depending on the application semantics." ε is "crudely two times the NTP offset value". The goal is to give enough room that "most (99.9%) NTP kinks can be masked smoothly." — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- Handling a clock far in the future, from the paper. "We simply ignore reception of messages that cause l value to diverge too much from pt. This prevention action fires if the sender of the message is providing a clock value that is significantly higher suggesting the possibility of corrupted clock." When bounds are broken, "we take the physical clock as the authority, and reset l and c values to pt and 0." Both actions "log the offending entries for inspection and raises an exception to notify the administrator." `c` is kept in bounded space so that a corrupt value "would in the worst case roll over." — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- Measured values on AWS. At 9 ms average NTP offset, the maximum l − pt was 107.9 ms, the 90th percentile was 41.4 ms and the mean was 4.2 ms. At 3 ms offset, the maximum was 7.4 ms. In simulation (1 event/ms, drift 10 to 100 ms), c ≤ 4 for more than 99% of events. A straggler that broke the drift bound reached c = 514, but only on itself. — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- The paper says HLC's masking of rushers and stragglers "makes it especially useful for last write wins (LWW) database systems like Cassandra." — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- Tie-breaking by node ID. The Elixir `hlclock` package "adds a node ID to each timestamp to break ties". It is on Hex (`{:hlclock, "~> 1.0"}`, versions up to 1.1.0) and runs as a supervised `HLClock` process with `send_timestamp/1`. — [hlclock README on Hex](https://preview.hex.pm/preview/hlclock/show/README.md)
- A production analogue. CockroachDB uses HLC with a default `--max-offset` of 500 ms. A node self-terminates when its mean offset to a majority of peers exceeds 80% of that value (about 400 ms). Reads use an uncertainty interval of [ts, ts + max_offset]. This comes from third-party guides; the official docs page found was only an old v20.1 errors page. — [Netdata CockroachDB guide](https://www.netdata.cloud/guides/cockroachdb/cockroachdb-clock-synchronization-error-500ms/); [CockroachDB v20.1 common errors](https://www.cockroachlabs.com/docs/v20.1/common-errors)
- Version vectors and DVV. A dot is "a single update, an event", for example {a, 3}. A plain version vector "is not enough to correctly track causality" when the actor "is a proxy for multiple clients". Vnode version vectors cause "false concurrency", which is sibling explosion. DVV stores one dot per sibling and discards the values the incoming vector has already seen. — [Riak, "Vector Clocks Revisited Part 2: Dotted Version Vectors"](https://riak.com/posts/technical/vector-clocks-revisited-part-2-dotted-version-vectors/); paper: [Preguiça et al., "Dotted Version Vectors: Logical Clocks for Optimistic Replication" (2010)](https://asc.di.fct.unl.pt/~nmp/pubs/tr-corr-2010.pdf)
- Riak sources disagree on the DVV default. The blog says DVV is "the default logical clock for bucket types" since Riak 2.0. The current docs say `dvv_enabled` defaults to false. — [Riak blog](https://riak.com/posts/technical/vector-clocks-revisited-part-2-dotted-version-vectors/); contradicted by [Riak conflict-resolution docs](https://docs.riak.com/riak/kv/latest/developing/usage/conflict-resolution)
- Shapiro et al.: "To detect concurrency, a scalar timestamp ... is insufficient", so the MV-Register stores (value, versionVector) pairs. — [Shapiro, Preguiça, Baquero, Zawirski, INRIA RR-7506 (2011)](https://hal.inria.fr/inria-00555588/document)

### Inferences
- With 2 to 10 known machines, a version vector costs at most 10 integers per record. A version vector or DVV per record is affordable, and it shows real conflicts (for example, two humans reordering the same feature offline) instead of hiding them.
- A practical scheme is an HLC with a node-ID tiebreak for the total order (LWW), plus a version vector for concurrency detection. This copies the paper's guard: reject or quarantine a remote change whose `l` exceeds local `pt + ∆` (∆ on the order of seconds to minutes for consumer machines; see the clock-skew section), and log it.
- The HLC monotonicity guarantee assumes each node persists its last (l, c) across restarts. A restart after a backward clock step without persisted state could reissue lower timestamps. This is my reasoning; I did not find it stated in the sources fetched.

### Gaps
- The common 48-bit l / 16-bit c layout comes from implementations (CockroachDB-style). The 2014 tech report only says "64 bits NTP timestamp format". I did not find a primary source for the exact split.
- I did not check a maintained TypeScript HLC package. The paper is simple enough (about 15 lines) that a hand-written version is reasonable, but none is cited here.

## LWW registers and LWW-element maps: semantics, anomalies, and the multi-value alternative

### Takeaway
An LWW register keeps the value with the highest unique timestamp. It converges, but it silently drops every concurrent write except one. Under clock skew, the machine whose clock runs fast wins, even when its edit is older in real time. Jepsen measured lost updates with as little as 1 s of skew. An MV register keeps all concurrent values and lets a human or a rule resolve them later.

### Cited Findings
- LWW-Register: "Timestamps are assumed unique, totally ordered, and consistent with causal order ... This may be implemented as a per-replica counter concatenated with a unique replica identifier." State merge "selects the value with the maximal timestamp". The op-based version applies an update "only if the new timestamp is greater than the current one", so concurrent assignments commute. — [Shapiro et al., RR-7506](https://hal.inria.fr/inria-00555588/document)
- LWW-element-Set keeps add-set A and remove-set R of (element, timestamp) pairs. Merge takes the union of both sets. An element is present if its add has no later remove. — [Shapiro et al.](https://hal.inria.fr/inria-00555588/document)
- Shapiro et al. note that in LWW-Set "the outcome of concurrent updates depends on opaque details of how timestamps are" allocated. — [Shapiro et al.](https://hal.inria.fr/inria-00555588/document)
- MV-Register merge "takes the union of every element in each input set that is not dominated by an element in the other input set". The Dynamo shopping-cart anomaly (a removed item reappears) shows that the MV-Register "does not behave like a set". — [Shapiro et al.](https://hal.inria.fr/inria-00555588/document)
- Jepsen on Cassandra: LWW without vector clocks means a concurrent update can overwrite a write without either client knowing. Writes were lost even with QUORUM, supposedly perfect clocks and an external lock. The earlier Riak test found that LWW dropped 30 to 70% of writes. — [aphyr, "Jepsen: Cassandra"](https://aphyr.com/posts/294-jepsen-cassandra)
- Jepsen on Scylla 4.2: with synthetic skew, "even one-second skews caused lost updates", and larger skews lost more writes. Their recommendation is lightweight transactions for non-commutative updates. — [Jepsen, Scylla 4.2-rc3](https://jepsen.io/analyses/scylla-4.2-rc3)
- Figma uses per-property LWW with a server that sets the order, so no timestamps are needed: "the document will just end up with the last value that was sent to the server." "Figma isn't using true CRDTs though." — [Figma, "How Figma's multiplayer technology works"](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/)
- Elixir: `delta_crdt` provides `DeltaCrdt.AWLWWMap` (an add-wins LWW map). Horde builds on it. It uses MerkleMap to find the keys to sync, the default sync interval is 50 ms, and it emits the telemetry event `[:delta_crdt, :sync, :done]`. — [delta_crdt hexdocs 0.3.1](https://hexdocs.pm/delta_crdt/0.3.1/DeltaCrdt.html); [delta_crdt 0.5.5 README](https://preview.hex.pm/preview/delta_crdt/0.5.5)

### Inferences
- Treat each field as its own register (rank, override, paused). Then concurrent edits to different fields do not conflict, which is Figma's per-property model.
- Pause flags and overrides are safety-relevant. An agent with a fast clock must not silently cancel a human's pause. Two options:
  - an MV-register that surfaces the conflict on the dashboard;
  - a deterministic policy that is not purely temporal, for example "pause wins over unpause under concurrency" (add-wins or remove-wins style) or "human origin beats agent origin under concurrency", with HLC/LWW used only among causally ordered or same-class writes.
- LWW is fine for low-stakes fields when HLC bounds skew and future timestamps are rejected.

### Gaps
- I found no published measurement of LWW anomaly rates for low-write-rate, human-scale workloads (a few edits per hour). The Jepsen numbers come from high-contention tests.

## CRDTs for ordered lists and priority sequences: RGA, Logoot, LSEQ, fractional indexing, and the move problem

### Takeaway
For priority order, the simplest working design is a fractional-index sort key per item, stored in an LWW register (or MV register). Moving an item is then one register write. This is Kleppmann's generic move construction, and it is what Figma does. Implementing move as delete plus insert duplicates items under concurrent moves. Sequence CRDTs (RGA, Logoot, LSEQ) are built for text and are heavier than this use case needs.

### Cited Findings
- Kleppmann: under concurrent moves, delete-and-reinsert duplicates the element. "two deletions of the same element behave the same as one deletion, and the two insertions independently re-insert the element twice". His motivating case is a to-do list "where the order may reflect the relative priority of tasks", reordered on a laptop and on an offline phone. — [Kleppmann, "Moving Elements in List CRDTs" (PaPoC 2020)](https://martin.kleppmann.com/papers/list-move-papoc20.pdf)
- His proposal: "pick one of the destination positions as the 'winner' ... Any deterministic method of picking the winner is suitable (e.g. based on a priority given to each replica, or based on the timestamp)". Implement it with one LWW register per element holding its position. Alternatively, use an MV register "if the LWW behaviour (discarding all but one of the concurrent moves of the same element) is unacceptable". The state is `AWSet({(v1, LWWRegister(p1)), ...})`. — [Kleppmann 2020](https://martin.kleppmann.com/papers/list-move-papoc20.pdf)
- The register needs a stable position ID, not an integer index. Logoot uses a list of (integer, replicaID) pairs, RGA uses s4vectors, and Causal Trees use timestamps. Moving ranges of elements is left open. — [Kleppmann 2020](https://martin.kleppmann.com/papers/list-move-papoc20.pdf)
- Figma fractional indexing: each child has an index that is "a fraction between 0 and 1 exclusive", stored as a base-95 string with arbitrary precision. An insert takes "the average index of the two objects on either side". Reordering "only involves editing a single value". The server breaks ties for identical indices. "Interleaving concurrently inserted elements in a design is usually fine", and "normal usage patterns never generate prohibitively-large index lengths." — [Figma, "Realtime editing of ordered sequences"](https://www.figma.com/blog/realtime-editing-of-ordered-sequences/)
- TypeScript: `rocicorp/fractional-indexing` provides `generateKeyBetween(a, b)` (with null for an open end) and `generateNKeysBetween` (more even spacing, shorter keys). It uses a base-62 alphabet by default. Keys must be sorted with plain string comparison, not `localeCompare`. Byte-compatible ports exist for Go, Python, Kotlin and Ruby. Jitter is advised for concurrent generation, through `jittered-fractional-indexing` (30 jitter bits by default). — [rocicorp/fractional-indexing](https://github.com/rocicorp/fractional-indexing/); [jittered-fractional-indexing README](https://unpkg.com/jittered-fractional-indexing@1.0.0/README.md)
- Tree moves, from "A highly-available move operation for replicated trees". A move op is (t, parent, meta, child). "timestamps ’t need to be globally unique and totally ordered (e.g. Lamport timestamps)". To apply an operation with timestamp t, the algorithm undoes all logged operations with a greater timestamp, applies the new one, then redoes them. An operation that would create a cycle is ignored. The log can be truncated below the "causally stable" threshold, which is the minimum over replicas of the latest timestamp seen from each, given a known replica set and FIFO links. The authors proved it in Isabelle/HOL. Throughput was about 5,700 ops/s optimised. — [Kleppmann, Mulligan, Gomes, Beresford, IEEE TPDS 2022 (PDF)](https://martin.kleppmann.com/papers/move-op.pdf); [blog landing page](https://martin.kleppmann.com/2021/10/07/crdt-tree-move-operation.html)
- Automerge move. A 2023 research extension (make/put/delete/move, "the move operation with the largest ID wins") exists. A 2025 paper says its authors "plan to integrate" a move algorithm into Automerge. I found no stable Automerge release with list move. — [arXiv 2311.14007](https://arxiv.org/html/2311.14007v1); [arXiv 2503.04811](https://arxiv.org/html/2503.04811v1)
- Linear: a reverse-engineering study describes server-ordered transactions with a monotonically increasing sync id, "closer to OT than CRDTs", and offline transactions cached in IndexedDB and resent later. The study does not describe Linear's sortOrder encoding. — [wzhudev/reverse-linear-sync-engine](https://github.com/wzhudev/reverse-linear-sync-engine) (secondary source)

### Inferences
- Priority lists here are short (tens to hundreds of items) and moves are rare. Fractional key + per-item LWW register is enough. Break key ties deterministically, for example by (key, item_id), so that equal keys from concurrent offline inserts still sort the same on every machine.
- Hierarchy (project > feature > ticket) is a tree. If items can change parent, a "parent" field in the same LWW register works when cycles are impossible by schema (fixed depth levels). Kleppmann's undo-redo log is only needed for arbitrary-depth reparenting.
- No Elixir fractional-indexing library was found. Porting the base-62 algorithm and checking it against the JS output (it is byte-compatible across ports) is small work.

### Gaps
- I did not verify Linear's own sort-order mechanism from a primary Linear source.
- I did not fetch Yjs's move semantics (Y.Array has no native move; this is from memory and not verified).

## Change-log designs: idempotent apply, origin tagging, op-based vs state-based sync, compaction

### Takeaway
Use op-based sync with a globally unique change ID (origin node + HLC). Apply is idempotent: skip an ID that is already applied, and the LWW comparison already ignores older ops. Echo is prevented by recording origin and never rebroadcasting an applied remote change as a new local change. Yjs does this with transaction origins, and Figma does it by discarding conflicting server echoes while local changes are unacknowledged. Compact the log below the causally stable threshold.

### Cited Findings
- CvRDT (state-based) vs CmRDT (op-based). Op-based updates "take effect only if the new timestamp is greater than the current one", so re-delivery of the same op is harmless for an LWW register. — [Shapiro et al.](https://hal.inria.fr/inria-00555588/document)
- Yjs echo control: check `transaction.local` or `transaction.origin`. Providers set origin to themselves for remote updates. Use an object (not a string) as the origin for your own writes. Some providers set origin wrongly (y-indexeddb reported `local=true, origin=null` on load), and "it is up to the provider to set local and origin correctly". — [Yjs forum: determining whether a transaction is local](https://discuss.yjs.dev/t/determining-whether-a-transaction-is-local/361); [beta.yjs.dev transactions](https://beta.yjs.dev/docs/api/transactions)
- Figma avoids flicker: clients "discard incoming changes from the server that conflict with unacknowledged property changes". Offline edits are reapplied on top of a freshly downloaded state when the client reconnects. — [Figma multiplayer](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/)
- Compaction and causal stability. With a known replica set, monotonic per-replica timestamps and FIFO links, "keep track of the most recent timestamp we have seen from each replica ... the minimum of these timestamps is the causally stable threshold". Operations at or below it can be discarded. — [Kleppmann et al., move-op](https://martin.kleppmann.com/papers/move-op.pdf)
- delta_crdt uses delta-state sync with MerkleMap diffing as a middle ground between op-based and full-state sync. — [delta_crdt 0.5.5](https://preview.hex.pm/preview/delta_crdt/0.5.5)

### Inferences
- Rules for "apply never republishes":
  1. Each change carries `{change_id, origin_node, hlc}`.
  2. Remote apply writes the register directly with the remote HLC and origin. It does not go through the local "edit" path that mints a new HLC.
  3. The outbound feed selects only `origin_node == self`, or forwards remote ops unchanged with their original ID (gossip). It never re-mints them.
  4. A dedupe set or per-origin high-water mark makes apply idempotent.
- Merging an incoming HLC into the local clock (the receive rule) is allowed and needed. Only minting a new change ID is forbidden.
- Compaction: when all 2 to 10 peers are known, keep a per-peer "last seen HLC" and truncate below the minimum. A peer that stays offline for a long time blocks truncation, so a bounded retention window plus a full-state resync fallback is the practical choice.

### Gaps
- No primary source fetched covering echo-loop failure case studies outside Yjs/Figma.

## Practical clock skew on consumer machines and bounding future timestamps

### Takeaway
Well-synced Linux machines stay within milliseconds. Stock Windows time sync is designed only for loose (Kerberos-grade) agreement. chrony may step the clock by large amounts at startup, and slews at up to 1/12 s per second by default. The HLC paper and CockroachDB both bound skew with a fixed ∆ and refuse changes that exceed it. For consumer machines, a ∆ of seconds is the paper's suggested scale. A cautious system should quarantine and surface far-future changes, not drop them silently.

### Cited Findings
- chrony `makestep threshold limit` steps the clock when the adjustment exceeds the threshold during the first `limit` updates. The doc example is `makestep 0.1 3`. The default `maxslewrate` is 83333.333 ppm (one twelfth). `maxupdateskew` defaults to 1000 ppm. Polling below 64 s "should generally not be used with public servers". — [chrony.conf(5), chrony 4.6](https://chrony-project.org/doc/4.6/chrony.conf.html)
- Windows: the default W32Time configuration targets the requirements of earlier releases (Kerberos, loose agreement within an AD forest). About 1 ms to UTC is possible on Windows 10 / Server 2016 1607+ only with explicit configuration. W32Time is "not a full-featured NTP solution that meets time-sensitive application needs". — [Microsoft, configuring systems for high accuracy](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/configuring-systems-for-high-accuracy); [Meinberg KB quoting the technical reference](https://kb.meinbergglobal.com/kb/time_sync/timekeeping_on_windows/configuring_w32time_as_ntp_client)
- HLC experiments: at 9 ms and 3 ms average NTP offset on AWS, the maximum l − pt was 107.9 ms and 7.4 ms. The paper proposes ∆ "on the order of seconds" with ignore and reset actions. — [Kulkarni et al.](https://cse.buffalo.edu/tech-reports/2014-04.pdf)
- CockroachDB default max offset is 500 ms, with self-termination at about 400 ms mean offset (third-party source). — [Netdata guide](https://www.netdata.cloud/guides/cockroachdb/cockroachdb-clock-synchronization-error-500ms/)
- Jepsen: 1 s of skew was enough to cause LWW lost updates in Scylla. — [Jepsen Scylla 4.2](https://jepsen.io/analyses/scylla-4.2-rc3)

### Inferences
- Suggested acceptance rule for remote changes:
  - accept if `remote.l ≤ local_pt + ∆`, with ∆ about 60 s for consumer laptops (generous, because a laptop resumed from sleep before NTP resyncs can be seconds to minutes off);
  - otherwise hold the change in a quarantine, show it on the dashboard and log it, as the HLC paper prescribes.
  - Do not clamp the timestamp, because clamping changes the change ID's ordering on different nodes and breaks determinism.
- A held change can be re-checked later. Once local time catches up it becomes acceptable, so convergence is delayed, not lost.
- Locally, mint HLCs from a monotonic-safe source: max(wall clock, last persisted l). This keeps a backward step after resume or an NTP step from issuing lower timestamps.

### Gaps
- I found no primary measurement of typical clock offsets on consumer laptops after suspend/resume, or of the size of clock jumps on resume. Treat the ∆ of about 60 s above as an engineering judgement, not a sourced figure.
- I read only part of the chrony suspend/RTC documentation; the page was truncated.
