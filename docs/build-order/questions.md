# Build Order Questions and Commands

This is the durable inbox for questions and operator actions during the Build
Order research and planning spike. Answers can be written directly below each
question or sent in chat; resolved items will be moved to the decision log in
the planning documents.

## Questions for Kevin

None currently. New boundary-changing questions discovered during review will
be added here and asked one at a time.

## Commands or Access Needed

- None currently. The Claude Design project is committed under
  `docs/build-order/prototype/` and recorded in `design-manifest.md`.

## Working Recommendations Pending Confirmation

- Same configured repository and read-only v1.
- One root GitHub issue per Build Order, selected from a constant `build-order`
  root label; direct native sub-issues define its members.
- Dashboard dependency editing, Linear, cross-repository orders, and more than
  100 direct tickets are follow-on scope.
- Provider quota/token/spend accounting is a separate companion dashboard
  track, not Build Order membership or acceptance work. Research recommends
  four pickable tickets: durable observations, cost/aggregation projection,
  account meters, and shared UI.

## Resolved

- Build Order v1 is limited to the single configured GitHub repository;
  cross-repository Build Orders are follow-on scope.
- Build Order v1 is a read-only projection of GitHub ticket metadata and
  dependency relationships; dashboard editing is follow-on scope.
- For flat subscription plans, per-ticket dollar values are versioned
  API-equivalent estimates derived from observed tokens. Display an asterisk,
  explain the estimate in an information popover, and identify the account's
  actual subscription tier; do not present the estimate as billed spend.
- Each render/reconnect joins current GitHub Build Order membership with data
  from the active Aiur instance and receives live push updates where available.
  These are the two live sources of truth.
- Total-build accounting includes all Aiur-retained usage attributable to each
  current member ticket, including usage recorded before membership was added.
- Reliable `claude-repl`/Claude Remote Control token-and-cost accounting is a
  required standalone companion ticket in this planning effort; incomplete
  Remote Control coverage is not the intended finished state.
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
  `model:codex` to each executable ticket, but do not apply `agent:todo` or
  otherwise dispatch work.
