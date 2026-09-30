# Guardian refactor gate on current main

Research base: merged `main@220b8f253`. Canonical finding
`platform-misc-29` calls the bare Guardian process loop an anti-pattern and
proposes a supervised `:gen_statem` plus per-receipt quarantine. The source
citations changed in PR #2879, so its old line anchors are currently unknown.
This note checks the safety contract before adopting that proposal; it does
not claim a runtime incident or authorize a rewrite.

- `Guardian.start/5` and `restore/3` still spawn a process directly
  (`guardian.ex:15-32`). `Reconciler.restore_all/3` halts on a failed
  restoration, and `init/1` stops boot (`reconciler.ex:18-32`). The repeated
  call clauses and testability concern remain plausible, but the proposed
  process type alone does not establish a user-visible improvement.
- The store already distinguishes malformed bytes from a newer receipt
  version. Tests show malformed bytes are saved under `.corrupt-*` and the
  store reinitializes (`ownership_reconciler_test.exs:73-95,177-190`); a readable
  newer-version file remains untouched and boot fails closed
  (`ownership_reconciler_test.exs:192-262`). A malformed individual receipt
  yields `{:invalid_workspace_receipt, %KeyError{}}` in
  `ownership_test.exs:446-447`.
- PR #2879 intentionally retains legacy unknown-provider holds, including
  Khala #533 generation 9012. Quarantining an individual receipt and then
  admitting that ticket would weaken this ownership boundary. A safe
  quarantine proposal must retain a durable per-ticket hold and show how the
  Executor sees and clears it; hiding a bad record to keep the daemon booting
  is insufficient.

**Disposition:** defer the `:gen_statem`/DynamicSupervisor rewrite as a
standalone refactor. First specify and test malformed-receipt behavior: whether
one ticket can remain durably held while unrelated tickets start, how a
receipt is archived without losing the hold, and what operator proof permits
release. Then compare a small deduplication of Guardian call plumbing against
the full process rewrite using behavior tests and a before/after line census.
This is an inference from the current source and the observed #533 safety
boundary; no live corrupt-receipt incidence has been counted.
