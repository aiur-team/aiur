# Threats to validity

Populate four evidence-based lists, naming unavailable evidence and explaining
empty lists. Do not copy a generic checklist as if every risk were observed.

- **Internal:** history (ledger events), maturation (fleet learning or queue
  mix drift), selection (complexity/model/ticket-size imbalance), instrumentation
  (capture or definition changes), regression to the mean (baseline chosen
  after an unusually bad period), novelty. A changed metric definition between
  windows makes that metric confounded; retaining its old name does not restore
  comparability. Record outages, missing records and censored/unmerged tickets.
- **Construct:** does the pack metric capture the hypothesis? Start-to-merge,
  for example, includes human review wait. A speed gain with worse cost or
  quality may not meet the intended outcome; use registered guardrails.
- **External:** applicability beyond the measured repo, operator, machine,
  model versions, capacity and queue mix. A backend cohort comparison cannot
  establish that every model on one backend behaves the same way.
- **Statistical conclusion:** low n, wide intervals, heavy tails, multiple
  comparisons, interim looks, SRM, exclusions and dependence among tickets.
  Explain whether the engine's unit of analysis matches the assignment unit.

Choose `keep`, `revert`, `extend-window`, `rerun-stratified` or `redesign` from
primary evidence and guardrails. Give numbers, the condition that would change
the action and next analysis (`at_n`, `on`, or `none`). When post-hoc or
confounded, qualify causality and propose the smallest rerun that addresses
the named threat; do not present an association as a treatment effect.
