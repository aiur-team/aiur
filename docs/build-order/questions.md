# Build Order Questions and Commands

This is the durable inbox for questions and operator actions during the Build
Order research and planning spike. Answers can be written directly below each
question or sent in chat; resolved items will be moved to the decision log in
the planning documents.

## Questions for Kevin

1. Should the first Build Order release support GitHub only, or must its data
   model and UI also work with Linear-backed workflows from day one?
2. At the end of planning, should I create the GitHub issues themselves, or
   stop after producing reviewed ticket documents that are ready to publish?
3. Should a Build Order be repository-wide, or can one Aiur instance display
   orders that span multiple repositories/projects?
4. May users add and edit dependencies from the dashboard in the first
   release, or is Build Order initially a read-only projection of GitHub issue
   metadata?
5. For flat subscription plans, should per-ticket “spend” be a versioned
   token-price estimate, an allocation of the subscription fee, or unavailable
   while tokens and quota consumption remain visible?
6. Should “total build” include all recorded usage for member tickets, or only
   usage observed after each ticket joined the Build Order?
7. Must v1 totals include direct `claude-repl`/Remote Control usage, or may the
   cards show explicitly incomplete coverage for that transport?

## Commands or Access Needed

- None currently. The Claude Design project is committed under
  `docs/build-order/prototype/` and recorded in `design-manifest.md`.

## Working Recommendations Pending Confirmation

- GitHub-only, same configured repository, read-only v1.
- One root GitHub issue per Build Order, selected from a constant `build-order`
  root label; direct native sub-issues define its members.
- Stop after reviewed ticket documents unless issue creation is explicitly
  authorized.
- Dashboard dependency editing, Linear, cross-repository orders, and more than
  100 direct tickets are follow-on scope.
- Provider quota/token/spend accounting is a separate companion dashboard
  track, not Build Order membership or acceptance work. Research recommends
  three pickable tickets: durable ledger, account meters, and shared UI.

## Resolved

- The opening request is the Build Order brain dump and authoritative product
  intent. No separate brain-dump document is required before planning.
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
