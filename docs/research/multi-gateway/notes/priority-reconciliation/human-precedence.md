# Human Precedence and Anti-Oscillation in Control Systems

Scope: how control systems (Kubernetes, GitOps tools, Terraform, schedulers, feature-flag services, building automation) let a human operator's intent beat automated adjustments; how they stop multiple automated controllers from oscillating; and how a later automated actor can deliberately supersede a human pin. Goal: design a precedence rule for a shared work-priority queue. Researched 2026-11-06 from primary docs where possible. Each item names its source.

## 1. Field ownership and drift handling (Kubernetes SSA, last-applied, HPA vs manual, Argo CD / Flux, Terraform)

### Takeaway
Kubernetes Server-Side Apply (SSA) is the closest prior art. Every field records its owner ("manager"). A write that would change a field another manager owns fails with a **conflict**. The writer must either drop its claim or **force** the write explicitly, which makes it the sole owner. GitOps tools add a second layer: per-field "ignore" rules and per-resource apply policies, so a declared source can step aside on the fields that another actor owns.

### Cited Findings
**Server-Side Apply field managers**
- The API server tracks *managed fields* on all new objects. A field is managed when "the user relies on and expects the value of the field not to change." The last writer becomes the field manager. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- "Whenever a field's value does change, ownership moves from its current manager to the manager making the change." — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- "A *conflict* is a special status error that occurs when an `Apply` operation tries to change a field that another manager also claims to manage." — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- There are two resolution options. (1) Overwrite: set `force=true` (`kubectl --force-conflicts`). This "changes the value of the field, and removes the field from all other managers' entries in `managedFields`." (2) Give up: remove the field from your own applied config and apply again. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- When two appliers set a field to the same value, they share ownership. A change by either one is then a conflict. A shared owner can give up ownership by applying a patch that leaves the field out. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- Ownership transfer is a two-step handshake: both managers set the same value (shared ownership), then one removes the field from its config. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- `managedFields` entries record `manager` and `operation` (`Apply` or `Update`). Imperative writes (`PUT`, non-apply `PATCH`) also take ownership, as `Update`. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- SSA has been stable since Kubernetes 1.22. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)

**last-applied-configuration (client-side apply)**
- The legacy `kubectl.kubernetes.io/last-applied-configuration` annotation tracks "a user's last applied state". SSA instead tracks per-field management. With client-side apply, "outdated values which have been overwritten by other users are left in an applier's local config." — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- When you migrate client-side to server-side, a field changed with `kubectl scale` after a client-side apply raises a conflict on `kubectl apply --server-side`. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)

**HPA vs manual replica edits**
- If a manifest keeps `spec.replicas` while an HPA is active, every `kubectl apply` scales back to the manifest value, "resulting in thrashing or flapping behavior". The documented fix is to remove `spec.replicas` from the manifest. This is a single-owner-per-field rule. — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- The handover has a race. If the user removes `replicas` before the HPA owns the field, the value resets to the default of 1. Safe procedure: leave `replicas` in the config until the HPA writes it and the user's next apply gets a conflict, then remove it. Alternative: apply a replicas-only manifest under a temporary manager (`--field-manager=handover-to-hpa`). That manager is deleted automatically when the HPA next writes the field. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- Human pause of an automated controller without editing the controller ("implicit maintenance-mode deactivation"): if the target's replicas are set to 0 while HPA `minReplicas > 0`, "the HPA stops adjusting the target (and sets the `ScalingActive` Condition on itself to `false`) until you reactivate it by manually adjusting" replicas or `minReplicas`. The HPA records a separate `ScaledToZero` condition so it can tell a zero it set itself from a human's deliberate zero. — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)

**Argo CD**
- `ignoreDifferences` can match JSON pointers, jq path expressions, or `managedFieldsManagers`. The last one ignores every field owned by a named manager, for example `kube-controller-manager`. — [Argo CD Diffing](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- By default, `ignoreDifferences` affects only the diff. The `RespectIgnoreDifferences=true` sync option is needed for sync to also leave those fields alone. It works only when the resource already exists. — [Argo CD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- With `ServerSideApply=true`, Argo CD runs `kubectl apply --server-side --force-conflicts`. It always forces, so it overrides other owners of fields it declares. Its manager name is `argocd-controller`. — [Argo CD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- A per-resource annotation `argocd.argoproj.io/ignore-differences` (JSON pointers only) and `Prune=false` give the operator a per-object opt-out. — [Argo CD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- Live-cluster changes do not trigger automated sync unless `selfHeal: true` is set. With self-heal, retries wait for `--self-heal-timeout-seconds` (5 s default) with exponential backoff. — [Argo CD Automated Sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- "Automated sync will only attempt one synchronization per unique combination of commit SHA1 and application parameters." A failed sync of the same commit and parameters is not retried automatically. This is an anti-loop rule keyed on the *intent version*. — [Argo CD Automated Sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- A controller or webhook that mutates an object after sync makes the app `OutOfSync`. Example: the HPA reorders `spec.metrics`. Fix: write Git in the controller's preferred form. — [Argo CD Diffing](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)

**Flux**
- The per-resource annotation `kustomize.toolkit.fluxcd.io/ssa` has four values. `Override` (default): "If you use `kubectl` to edit a Kubernetes resource managed by Flux, all changes will be reverted." `Merge`: keeps fields from other tools that do not overlap. `IfNotPresent`: create only, never update. `Ignore`: skip the resource. — [Flux Kustomization](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- Ignored fields (`.spec.ignore`) are handled by ownership. If another SSA manager owns the field, Flux strips it from its payload. If Flux is the sole apply manager, it copies the in-cluster value into the payload ("adopt"). This keeps `kubectl edit` changes instead of reverting them. "Changes to ignored fields alone do not trigger a reconciliation." — [Flux Kustomization](https://fluxcd.io/flux/components/kustomize/kustomizations/)

**Terraform**
- `lifecycle { ignore_changes = [...] }` makes Terraform ignore listed attributes when it plans updates. Use it when an outside process changes them. The attributes still apply at create. `ignore_changes = all` means Terraform "will never propose updates" to the object. — [Terraform lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- `prevent_destroy` rejects any plan that would destroy the resource. It is a hard guard, and the operator must remove it to proceed. — [Terraform lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)

### Inferences
- The shared pattern is **per-field ownership + conflict-on-foreign-write + explicit force**. Mapped to a priority queue: each priority value carries an `owner` (human / scheduler / Executor-id). An automated write to a human-owned value is *rejected as a conflict*, not silently applied. To supersede, the actor must send an explicit `force` that is recorded.
- Argo CD's "one attempt per (commit, params)" maps to "an automated actor acts at most once per intent version". The scheduler must not reapply the same decision after a human rejects it unless the inputs change.
- The HPA `ScaledToZero` vs manual-zero split is a precedent for storing *who* set a value. The same value can mean "automation, may change" or "human, hold".
- The Flux "strip vs adopt" rule shows that even an ignore rule needs ownership data to act correctly.

### Gaps
- I did not fetch the `app.kubernetes.io/managed-by` / `endpointslice.kubernetes.io/managed-by` wording. The page was truncated. These are known conventions: a label that names the single controller allowed to reconcile an object. Verify at https://kubernetes.io/docs/reference/labels-annotations-taints/ before you cite.
- Argo CD `compare-options` annotation (e.g. `IgnoreExtraneous`) not verified.

## 2. Authority levels and source precedence (manual override with expiry, pins, scheduler admin overrides, PriorityClass, feature flags)

### Takeaway
Mature systems use an **ordered list of sources** in which a more specific or more authoritative source wins (BACnet's 16-slot priority array; LaunchDarkly's off → prerequisites → individual targets → rules → default). Overrides are released explicitly (write NULL / "release"), or they expire after a time or at the next scheduled event (thermostat holds). In Slurm, an admin's explicit priority stays fixed: the plugin no longer recalculates it until the admin releases it.

### Cited Findings
**BACnet priority array (building automation; the canonical human-vs-automation design)**
- Each commandable property has a 16-level `Priority_Array`. Level 1 (Manual Life Safety) is the highest. The present value is the non-NULL entry at the highest level. If all 16 are NULL, `Relinquish_Default` applies. — [Chipkin: BACnet priority array](https://store.chipkin.com/articles/bacnet-what-is-a-bacnet-priority-array); [OPC/BACnet command prioritization](https://reference.opcfoundation.org/specs/OPC-30030/3.2.1)
- Manual operator override is conventionally level 8. Johnson Controls lists 8 as "Operator override (manual operator)" and 16 as default (schedules and automation sit lower). Some vendors differ. Schneider Continuum defaults a manual write to 10. — [Johnson Controls Metasys: Command Priority Levels](https://docs.johnsoncontrols.com/bas/r/Metasys/en-US/Controller-Tool-Help/15.0/Input-and-Output-Objects/Command-Priority-Levels); [Schneider community](https://community.se.com/t5/Building-Automation-Knowledge/Controlling-command-priorities-with-Continuum-workstation/ta-p/8042)
- To release an override, write NULL at that level. Control then falls back to the next active level. Lower-priority writers keep writing into their own slots and never overwrite the operator's slot. — [Inductive Automation forum](https://forum.inductiveautomation.com/t/bacnet-relinquish-release-analog-output/68517); [Chipkin](https://store.chipkin.com/articles/bacnet-why-doesn039t-the-present-value-change)
- Project Haystack's writable-point model uses the same 16-level array. — [Project Haystack writable-point](https://project-haystack.org/doc/lib-phIoT/writable-point)

**Override with expiry (thermostats)**
- ecobee "Hold Action" options: 2 hours, 4 hours, until next scheduled activity, until you change it, and ask each time. Through the API, a hold can be indefinite, next transition, or N hours. Some quick-action paths set indefinite holds that ignore the setting. — [support.com guide](https://www.techsolutions.support.com/how-to/how-to-set-hold-action-duration-on-ecobee-thermostat-12337); [Home Assistant community](https://community.home-assistant.io/t/ecobee-support-hold-type-and-hold-hours-for-temperature-holds/94892). (Community and vendor-adjacent sources, not official ecobee docs.)

**Slurm**
- Multifactor priority is a weighted sum of age, association, fair-share, partition, QOS, site, and TRES factors, minus nice. Fair-share usage decays with `PriorityDecayHalfLife` (default 7 days). — [Slurm multifactor priority](https://slurm.schedmd.com/priority_multifactor.html)
- "When a privileged user explicitly sets a job's priority, it is fixed and the priority plugin will no longer modify it." To return control to the plugin, hold and then release the job. Priority 0 = held. Unprivileged users can only lower priority. `scontrol top` reorders by adjusting nice values. — [Slurm scontrol](https://slurm.schedmd.com/scontrol.html)

**Kubernetes PriorityClass**
- User values go up to 1,000,000,000. Larger values are reserved for system classes (`system-cluster-critical` 2,000,000,000; `system-node-critical` 2,000,001,000). One `globalDefault` is allowed. Without one, the default priority is 0. — [K8s Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- `preemptionPolicy: Never`: the pod queues ahead of lower-priority pods but "cannot preempt other pods". This separates *ordering* from *eviction*. — [K8s Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- Untrusted users could set the highest priorities. Admins limit this with ResourceQuota. In other words, the *right to set* a priority level is itself access-controlled. — [K8s Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

**Nomad**
- A job can preempt allocations only from jobs whose priority is at least 10 lower. This stops cascading preemption among jobs with close priorities. Preemption is on by default only for system jobs. Operators configure it with `nomad operator scheduler set-config`. — [Nomad preemption](https://developer.hashicorp.com/nomad/docs/concepts/scheduling/preemption)

**LaunchDarkly targeting precedence**
- Evaluation order: flag off → off variation; prerequisites (recursive, no cycles); individual targets ("Targets take priority over rules"); custom rules top-down, first match wins; default rule (fallthrough). Individually targeted contexts bypass default-rule rollouts. — [LaunchDarkly: Flag evaluation rules in server-side SDKs](https://launchdarkly.com/docs/sdk/concepts/flag-evaluation-rules); [LaunchDarkly targeting](https://launchdarkly.com/docs/home/flags/target)

### Inferences
- A BACnet-style **priority array per queue item** fits the problem directly. Slots could be: `human` (high) > `executor` > `scheduler` > `default`. Each actor writes only its own slot. The effective priority is the highest non-empty slot. The scheduler can keep recomputing its slot all the time without ever undoing the human. The human "releases" by clearing the slot. This avoids oscillation by construction, because writers never overwrite each other.
- Slurm's "fixed until hold+release" and ecobee's "until next scheduled activity / N hours" are the two expiry styles: explicit release vs time- or event-bound expiry. A dashboard edit can default to "hold until released" or "until the feature completes". A TTL is optional.
- The Nomad delta ≥10 rule is a form of hysteresis on priority: small differences do not trigger reordering or preemption.

### Gaps
- Nomad's job priority range and default (commonly 1–100, default 50) were not verified this session. See https://developer.hashicorp.com/nomad/docs/job-specification/job.
- Slurm QOS-specific admin overrides (`UsageFactor`, `Flags=OverPartQOS`) were not fetched.

## 3. Anti-oscillation (hysteresis, stabilization windows, leader-only writes, intent vs observed, versioned intent)

### Takeaway
The HPA documents the standard toolkit. A **tolerance band** (10%) ignores small changes. **Asymmetric stabilization windows** (300 s for scale-down, 0 s for scale-up) use the most conservative recommendation in the window. **Rate policies** cap change per period. A **Disabled** switch turns off one direction. GitOps adds "act once per intent version" and backoff.

### Cited Findings
- The HPA names "thrashing" or "flapping" and compares it to hysteresis. Mitigations: "a *stabilization window* for smoothing replica counts, and a tolerance to ignore minor metric fluctuations below a specified threshold." — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- The scale-down stabilization default is 300 s. Scale-up has no window ("scaled up immediately"). — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- The default tolerance is 10% cluster-wide. Per-HPA `tolerance` can be set per direction. Example: a 5% tolerance on a 100 MiB target means scale-up only above 105 MiB. — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- Default policies: scale-down 100% per 15 s. Scale-up is max(100% or 4 pods per 15 s) (`selectPolicy: Max`). `selectPolicy: Disabled` "completely disables scaling in that direction." The HPA loop runs every 15 s by default. — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
- Argo CD self-heal waits 5 s, then backs off exponentially. It does not retry a failed sync of the same commit and parameters. — [Argo CD Automated Sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- Two writers that both declare the same field (GitOps apply + HPA) cause thrashing. Kubernetes fixes this with a single owner per field, not with a timer. — [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/); [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- Intent vs observed split: SSA tracks declared intent per manager (`managedFields`) apart from the live value. Argo CD can ignore `status` for diffing because status "cannot be applied as a desired configuration". — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/); [Argo CD Diffing](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)

### Inferences
- For a priority queue: (a) one owner per item's priority slot removes the root cause. (b) A stabilization window on *demotion*: the scheduler may raise priority at once but must not lower a recently changed item within N minutes. (c) A tolerance band: do not reorder for score differences below a threshold, as in Nomad's delta ≥10. (d) Record `intent_version` with `origin` and `author`. Automated actors act at most once per (intent_version, inputs) pair.
- Leader-only writes: with 2–10 machines, run one scheduler instance as writer (lease-elected). That makes it one automated writer per slot, so the "two automated controllers" problem becomes "one automated controller + humans + Executors, each in its own slot".

### Gaps
- No Kubernetes leader-election (Lease) doc was fetched this session. The leader-only-writes claim is a design inference, not a cited finding.

## 4. Deliberate supersession (force, takeover with reason, audit)

### Takeaway
Systems let a lower-authority or automated actor beat an owner only by an **explicit, distinguishable action**: SSA `force=true`, Slurm privileged `scontrol update Priority=`, BACnet writing at a higher level, Terraform removing a `prevent_destroy` guard. The force is recorded: SSA rewrites `managedFields` to the forcing manager, so the audit trail shows who took over.

### Cited Findings
- SSA force "removes the field from all other managers' entries in `managedFields`". Ownership moves visibly to the forcing manager. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- In the temporary-manager handover, a named manager (`handover-to-hpa`) documents intent and disappears when the new owner writes. — [Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- Argo CD always forces (`--force-conflicts`) when SSA is on. A GitOps controller that forces blindly does *not* respect other owners unless ignore rules exclude those fields. This is the anti-pattern for a "human must win" system. — [Argo CD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- Slurm: only privileged users can set a fixed priority or a negative nice. Unprivileged users can only lower priority. Supersession is gated by authority level. — [Slurm scontrol](https://slurm.schedmd.com/scontrol.html)
- Kubernetes gates who may use high PriorityClasses through ResourceQuota. — [K8s Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- `prevent_destroy` makes a dangerous plan fail with an error. The operator must edit the guard to proceed. — [Terraform lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)

### Inferences
- A rule for the queue: the scheduler (background, non-deliberate) may **never** force a human slot. An Executor may supersede a human pin only with `force: true` + a mandatory `reason`. That writes a new intent version with `origin=executor`, `author`, `reason`, `supersedes=<human version>`. The surface shows the takeover to the human (as in SSA, where ownership visibly moves). The "later deliberate change wins" requirement is then met by *explicitness*, not by recency. A non-forced Executor write to a human-owned item gets a conflict response and is ignored.
- Optional: rate-limit forced takeovers (for example, one per item per hour) so two Executors cannot thrash through repeated forces.

### Gaps
- No primary source covers "takeover with reason" fields in a mainstream scheduler. PagerDuty incident reassignment and Kubernetes `kubectl cordon` reason annotations were not researched.

## 5. Fair-share and priority-with-borrowing (YARN, Kueue, Slurm) as prior art for "focus one feature, never leave slots idle"

### Takeaway
Every major batch scheduler separates a **guaranteed share** from **elastic borrowing of idle capacity**. Borrowed capacity can be reclaimed, by preemption or by waiting, when the owner needs it. This matches "focus feature gets first claim, and spare slots go to other work rather than sitting idle".

### Cited Findings
- YARN Capacity Scheduler: queues get a guaranteed capacity fraction. "Free resources can be allocated to any queue beyond its capacity." `maximum-capacity` "limits the *elasticity*". Preemption reclaims containers from queues above their guaranteed capacity (with ProportionalCapacityPreemptionPolicy). `minimum-user-limit-percent` gives each user a floor inside a queue. — [YARN Capacity Scheduler](https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/CapacityScheduler.html)
- Kueue: each ClusterQueue has a `nominalQuota` (guaranteed). ClusterQueues in a cohort borrow unused quota up to `borrowingLimit` (unset = all the others' nominal quota). `lendingLimit` keeps part reserved. Example: team-a (9 CPU) can use 21 CPU when team-b (12 CPU) is idle. With `borrowingLimit: 1` it can use only 10. — [Kueue ClusterQueue](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- Kueue admits workloads that fit nominal quota first. Workloads that need to borrow are sorted by priority. `reclaimWithinCohort` (`Never`/`LowerPriority`/`Any`) controls whether an owner can preempt borrowers to reclaim quota. `borrowWithinCohort` controls preemption while borrowing (Classical preemption only). — [Kueue ClusterQueue](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- Slurm fair-share compares promised vs consumed resources, with usage decaying by half-life (default 7 days). Over-consumers drift down and do not get starved forever. — [Slurm multifactor priority](https://slurm.schedmd.com/priority_multifactor.html)
- Kubernetes `preemptionPolicy: Never` lets high-priority work jump the queue without evicting running work. — [K8s Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

### Inferences
- Model "focus feature" as a cohort member with a large nominal quota (for example, most slots), and the rest as borrowers. With `reclaim = wait` (no preemption, like `preemptionPolicy: Never`), running agents are not killed. The focus feature gets the next free slot first, and idle slots always go to the next-ranked ready work. That is the "never idle" property.
- Add `borrowingLimit` per non-focus feature so one side lane cannot fill the machine while the focus feature has ready work blocked behind dependencies.
- Fair-share decay is the anti-starvation counterweight. Without it, a permanent focus feature starves everything else.

### Gaps
- Kueue Fair Sharing (DRF-based weights) and YARN queue priority / `user-limit-factor` details were not fetched.
- No source gives scale guidance for 2–10 machines. All these schedulers target large clusters. Their concepts map down well, but their tuning defaults (for example, the 5-minute stabilization) are not validated at small scale.
