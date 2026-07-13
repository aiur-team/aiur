# Build Order Questions and Commands

This is the durable inbox for questions and user/Executor actions during the Build
Order research and planning spike. Answers can be written directly below each
question or sent in chat; resolved items will be moved to the decision log in
the planning documents.

## Questions for Kevin

Five decision items from the independent second review — full context and
recommendations in
[09-plan-review-synthesis.md](09-plan-review-synthesis.md#questions-for-kevin-decision-ledger):

1. Usage/cost accounting family (17 tickets): keep / cut to design-parity
   slice (recommended) / drop.
2. Publication ceremony: keep full receipt machinery or collapse to minimal
   render+publish + requery-diff + human body review (recommended).
3. Ratify the merge-candidate list (mutually-serialized pairs; no parallelism
   cost).
4. Ratify the structural parallelism changes (per-page LiveViews; BO-012 sans
   BO-011; DASH-003/BO-018 and DASH-001/BO-008 as contract deps).
5. Add an executable owner for /aiur-build automation verification.

## Operator decisions recorded 2026-07-13

- **Single Build Order (decided and executed):** the operator decided on one
  consolidated Build Order containing every ticket in the program (all BO +
  DASH work) so agents parallelize across the whole graph, and the pack now
  implements it — all 54 tickets are direct members of the one root in
  `build-order.json`, denominators and capstone semantics updated (DEC-014).
  Ledger question 1 (accounting family) is resolved as **keep — included in
  the consolidated graph**; its two human Claude-protocol gates (GATE-003 on
  DASH-019, GATE-004 on DASH-013) remain visible in-graph blockers.
- **Epic labels are the planner's choice:** docs/frontend/backend/infra were
  prototype examples. This program's preview uses plan-graph / runtime /
  dashboard-ui / accounting / platform. The /aiur-build skill now instructs
  planners to choose 3–6 fitting lanes, fold one-ticket lanes, and key icons
  from the BO_ICONS line-art library.
- **Plan breakdowns are product scope:** per-phase and per-epic count/point
  breakdowns ship on the real Build Order page — added as BO-020 (validated,
  0 errors) with BO-015 capstone coverage; after consolidation the root holds
  54 members, 56 issues / 107 blocker edges at publication.
- **Skill delivery = merge PR #1065** when planning wraps (constraint on the
  prior run is gone); branch reconciled with main and green.

## Commands or Access Needed

- Rotate the dashboard Basic Auth credential pasted into chat. It will not be
  copied into commands or tracked files. The supplied screenshots and audited
  `origin/main` source are sufficient for the current delta pass; if later
  authenticated browser evidence is required, provide a fresh credential via
  a local `chmod 600` file path rather than chat.
- Before any later dispatch, the user and runtime Executor must resolve the
  integration-baseline and installed-skill gates recorded in
  `build-order.json`. They do not block planning publication.
- The Claude Design project is committed under `docs/build-order/prototype/`
  and recorded in `design-manifest.md`; no design access is pending.

## Accepted Planning Baseline

- Same configured repository and read-only v1.
- One root GitHub issue per Build Order, selected from a constant `build-order`
  root label; direct native sub-issues define its members.
- Dashboard dependency editing, Linear, cross-repository orders, and more than
  100 direct tickets are follow-on scope.
- Provider quota/token/spend accounting is a separate companion dashboard
  track, not Build Order membership or acceptance work. The final capability
  audit decomposes it into provider envelope, ledger, aggregate query,
  retention/compaction, Remote Control adapter, pricing/grouping, two meter
  adapters, run summary, shared UI, and selected-order integration.

## Resolved

- Build Order v1 is limited to the single configured GitHub repository;
  cross-repository Build Orders are follow-on scope.
- Build Order v1 is a read-only projection of GitHub ticket metadata and
  dependency relationships; dashboard editing is follow-on scope.
- For flat subscription plans, per-ticket dollar values are versioned
  API-equivalent estimates derived from observed tokens. Display an asterisk,
  explain the estimate in an information popover, and identify the account's
  actual subscription tier only when usage and meter facts share an exact known
  provider/backend/account generation; do not present the estimate as billed
  spend or guess a tier for unknown, mixed, or mismatched generations.
- A run/build may show one asterisked API-equivalent total across Codex, Claude,
  and multiple account generations when the currency is compatible. Preserve
  every provider/account-generation contributor and its exact tier join;
  never mix currencies or provider-reported and API-equivalent bases.
- Each render/reconnect joins current GitHub Build Order membership with data
  from the active Aiur instance and receives live push updates where available.
  These are the two live sources of truth.
- Total-build accounting includes all Aiur-retained usage attributable to each
  current member ticket, including usage recorded before membership was added.
- Reliable `claude-repl`/Claude Remote Control token-and-cost accounting is
  required work in dedicated members of the consolidated Build Order;
  incomplete Remote Control coverage is not the intended finished state.
- The opening request is the Build Order brain dump and authoritative product
  intent. No separate brain-dump document is required before planning.
- Build Order v1 is GitHub-only. Linear parity is separate, human-blocked work
  tracked in [#1067](https://github.com/its-everdred/aiur/issues/1067) and does
  not affect this feature's scope, critical path, ticket count, or ETA.
- Work may be committed early and often with 3–7 word commit messages and
  pushed regularly.
- Do not merge any work into `main` while the dashboard agents are active.
  Keep all changes isolated on review branches.
- This spike does not run Aiur or implement the Build Order feature. Its two
  outcomes are the researched feature breakdown and a reproducible
  `/aiur-build` skill for future breakdowns.
- Roughly ten Build Order implementation tickets is the initial sizing
  hypothesis, not a required count; dependency boundaries and reviewability
  determine the final recommendation.
- After Kevin reviews the ticket documents, materialize the approved root and
  implementation issues in GitHub. Apply one `complexity:N` label and
  `model:codex-gpt-5.6-terra` to each executable ticket, but do not apply
  `agent:todo` or otherwise dispatch work.
- The authorized materialization set includes all 54 direct root members
  (BO-001..020 and DASH-001..034) and one parentless human-blocked issue
  preserving the isolated skill PR #1065. The user explicitly asked that these
  unrelated skill changes not fall through the cracks and delegated the choice
  of a separate ticket.
- Do not comment on, close, relabel, or rewrite existing #132, #845, #1033,
  #1034, or #1067 during publication; the new issue bodies may cite their
  overlap. No additional mutation authority is inferred from permission to
  create the approved set.
