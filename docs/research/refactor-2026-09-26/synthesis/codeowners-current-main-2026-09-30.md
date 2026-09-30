# CODEOWNERS trust at `main@b4bc11f`

Two independent read-only reviews checked the plan's KTD9 contract against
detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. This is a source
map and test contract, not runtime verification.

Already present: `Aiur.GitHub.CodeOwners` alerts on a missing, empty or
unparseable CODEOWNERS file and retains configured bot, daemon and trusted
accounts (`github/code_owners.ex:181-260,380-391`). The event sanitizer
stamps trust and sanitizes untrusted bodies; the PR command scanner requires
true trust and the agent event digest filters untrusted content
(`events/sanitizer.ex:135-210`, `events/pr_command_scanner.ex:70-77`,
`agent_runner/events_digest.ex:25-44`). IssueLog persists event evidence.

| Current-main gap | Evidence | Focused proof before implementation |
| --- | --- | --- |
| Team lookup failure looks healthy. | `github/code_owners.ex:181-203,475-485` converts a failed `GitHub.Teams` read to `[]` while the snapshot remains `source: :file` without cause or observed age. | Fail page two or return 403; assert unknown trust, alert cause/age, and no newly authoritative member. |
| A second path authority can keep revoked members. | `Aiur.Codeowners` parses separately; `codeowners.ex:409-425` caches successful team members in the caller's process dictionary without expiry. | Resolve a member, revoke them on refresh, and prove a later comment is no longer authoritative in both event and path flows. |
| Path and team context can be partial. | `codeowners.ex:433-456,477-499` reads one page of team members and PR paths; `ownership_for_paths` may treat the resulting subset as complete. | Exercise 101+ changed paths and team members, plus a held second page; require a complete set or explicit unknown, never a smaller authoritative set. |
| Configured identities and repo owner differ by path. | `github/code_owners.ex:195-237` adds the repository owner only when the whole allowlist is empty; `codeowners.ex:113,215-223` returns unknown on ownership error before consulting configured identities. | Test bot plus owner, explicit and origin-derived repository resolution, unavailable origin, and configured trusted author during a failed path/team lookup; keep agent-self exclusion. |
| Executor visibility is not proved end to end. | Sanitizer/IssueLog preserve sanitized structure and agent digest excludes untrusted bodies, but trust snapshot/CLI lack observation age (`github/code_owners.ex:322-330`, `agent_control_cli.ex:2279-2295`). No dashboard body-render test was found. | Send one untrusted comment through poll/firehose, publisher, IssueLog and real dashboard/TUI view; assert sanitized body/cause/age visible to Executor, absent from agent digest, and unable to issue a command. |

`RunTelemetry.GitHubEnricher` also has a fallback owner/config decision when
the trust server is absent (`run_telemetry/github_enricher.ex:291-309`); align
it with the same fail-closed snapshot or decline to classify trust. The first
repair seam is the existing `Aiur.GitHub.CodeOwners` authority and paginated
`GitHub.Teams` reader. Do not introduce a new trust service or infer that an
unknown membership is a negative membership fact.
