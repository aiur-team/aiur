# Build Order Questions and Commands

This is the durable inbox for questions and operator actions during the Build
Order research and planning spike. Answers can be written directly below each
question or sent in chat; resolved items will be moved to the decision log in
the planning documents.

## Questions for Kevin

1. Please send the Build Order brain dump and the high-level draft spec when
   ready.
2. Should the first Build Order release support GitHub only, or must its data
   model and UI also work with Linear-backed workflows from day one?
3. At the end of planning, should I create the GitHub issues themselves, or
   stop after producing reviewed ticket documents that are ready to publish?
4. Should a Build Order be repository-wide, or can one Aiur instance display
   orders that span multiple repositories/projects?
5. May users add and edit dependencies from the dashboard in the first
   release, or is Build Order initially a read-only projection of GitHub issue
   metadata?

## Commands or Access Needed

- Claude Design project import: Kevin is arranging a local export because the
  `claude_design` connector is unavailable in this Codex session. When ready,
  place it in the workspace and send its repo-relative path.

## Resolved

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
