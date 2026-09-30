# Reconciled P2/P3 decisions at `main@b4bc11f`

The two effective-decision audit scripts pass at this research branch:
`audit_p2p3_triage.py` covers 889/889 canonical findings and
`audit_p2p3_reconciled.py` covers all 17 reconciliation decisions, producing
244 provisional fixes and 645 deferrals. Two independent read-only reviews
then checked the nine IDs whose effective verdict or action changed against
detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. All nine mechanisms
remain source-reachable; none has measured runtime incidence or an executed
failure-path test. This does not revalidate the other 880 findings.

| IDs | Current-main source contract | Gate before a repair ticket |
| --- | --- | --- |
| `github-a-19` | Every App installation entry resolves through one refresher (`github/credential.ex:46-56,81-84`), while the configuration reference describes per-entry minting (`website/docs-app/reference/configuration.md:96-98`). | Decide whether multiple installations are supported; use two distinct entries to test token and attribution identity, or correct the documentation and reject ambiguous config. |
| `github-a-36` | `current_token/0` ignores cached expiry and `init/1` may acquire synchronously (`github/app_token_refresher.ex:59-69,98-128`). | Test expired cache and blocked startup separately; do not treat a startup latency choice as proof of token validity. |
| `github-b-14` | An injected request function can enable a literal test token (`github/transport.ex:79-91`). | Exercise injected transport without credentials; make the authentication policy explicit while preserving legitimate tests and budget attribution. |
| `loose-1-10` | Initial accept calls the ID generator directly (`decision_store.ex:2419-2424`), bypassing the configurable `event_id_reserver` at line 581. | Force that direct reservation call to exit; assert defined failure and subsequent writer availability. A test that injects only `event_id_reserver` misses this branch. |
| `nonelixir-web-08` | Stream Deck controller history input scrolls only loaded items (`packages/streamdeck/src/controller.ts:819-830,879-884`); the channel exposes cursor paging (`channel.ts:338-344`). | Supply a second page and assert input requests, retains and renders older commands; cover end and error states. |
| `skills-prompts-cont-07` | Remote review fetches `origin` by PR branch name without comparing it with `headRefOid` (`.claude/skills/ce-code-review/SKILL.md:258-275`). | In a fork/origin same-name branch fixture, require the inspected source and diff to match the PR head SHA. |
| `skills-prompts-cont-19` | CE work instructions both forbid isolated worker commits and prescribe merging isolated branches, then permit those commits (`.claude/skills/ce-work/SKILL.md:176-209,299-302`). | Preserve an isolated worker edit through the documented integration path with one commit-owner rule. |
| `skills-prompts-cont-20`, `-21` | Release instructions bump only Mix and verify `bin/aiur` after `mix escript.build` (`.claude/skills/release/SKILL.md:39-49`); workflow checks the checked-in launcher package version (`.github/workflows/release-npm.yml:69-77`), and Mix writes `bin/aiur.escript` (`src/mix.exs:201-212`). | A Mix-only bump must fail before tagging; a stale `bin/aiur` cannot satisfy verification of a freshly built artifact. Check all publishable package metadata explicitly. |

The current release recipe also has separate source-reachable `-46` and `-47`
gates in the existing [reconciliation overlay](p2p3-triage-reconciliation-overlay.md):
verify the canonical tag SHA before creating its GitHub release, and verify
workflow plus registry receipts before saying npm publication succeeded. The
current `0.0.7` checked-in version alignment is incidental; it does not make
the generic release recipe correct.
