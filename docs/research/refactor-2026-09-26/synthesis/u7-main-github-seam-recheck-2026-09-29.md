# U7 GitHub access seam at merged main

Read-only source audit at `ec2901a31f1264939529a7186ffc1314e970252d`, following the [candidate audit](u7-github-seam-candidate-2026-09-29.md). The core `Transport`, `ResourceStore`, `ResourceFetch`, `Teams`, `CodeOwners`, `Aiur.Codeowners`, and application startup files are byte-identical to the pinned raw-research base `4479caaa`; later edits to `Client`, `PullRequests`, `ReadCache`, and the poller have not changed the ownership boundary. This is static evidence, not a release-boot or failure-injection result.

## Current callers and ownership

An executable-reference scan under `src/lib/aiur` (excluding comments, docs, tests and dynamic calls, and including `GitHubClient` aliases) found three active entry points:

| Entry point | Caller modules / call expressions | Outside `github/` |
| --- | ---: | ---: |
| `GitHub.Transport` | 43 / 251 | 12 / 28 |
| `GitHub.Client` | 16 / 40 | 14 / 32 |
| `GitHub.ResourceStore` | 27 / 151 | 12 / 70 |

This is a source census, not an observed runtime distribution. `Client` is not the only existing entry point, and wrapping all calls with it would add a facade before removing duplicate behavior. `Transport` owns credential selection followed by cache and quota admission ([transport](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur/github/transport.ex#L94-L174)). The application orders headroom, cache, quota, durable store, bridge and publisher in its `:rest_for_one` tree ([startup](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur.ex#L324-L372)). `ResourceFetch` already owns strict/held/revalidation outcomes and compare-and-set publication races ([resource fetch](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur/github/resource_fetch.ex#L92-L143)). A new package, supervisor or global facade has no demonstrated benefit yet.

## Smallest consolidation to validate

Treat the duplicated `Aiur.Codeowners` GitHub lookups as U5 trust-boundary work. Its private team reader is one-page while `Teams.fetch_team_members/3` already paginates. Its private PR-path reader is also one-page, **and so is** the shared `PullRequests.fetch_pull_request_changed_paths/2`: it calls one-request `Transport.fetch_json_list/4` with `per_page=100` ([shared reader](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur/github/pull_requests.ex#L13-L29), [transport helper](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur/github/transport.ex#L676-L700)). Make the shared PR reader complete and fail on a later-page error before using it as the single path. Preserve `Aiur.Codeowners` explicit `:repo`, `:token`, and `:request_fun` options and its unknown-on-error decision. Check first and last pages, later-page 403/429, missing or invalid repo, and the resulting review authority. No partial list may be authoritative.

Only then compare remaining call sites for duplicated behavior. Do not replace the poller and CommandScan comment-list ETag paths with `ResourceFetch.need/2` without checking publication order: the poller currently publishes before storing ([poller](https://github.com/aiur-team/aiur/blob/ec2901a3/src/lib/aiur/github_comments_poller.ex#L255-L303)), while `ResourceFetch` stores before publication. That swap could lose crash-recovery behavior. No quota saving or physical extraction is established by this audit.

The next U7 gate remains an actual release boot and restart/failure-injection matrix for credential choice, budget accounting, cache fallback and durable identity in foreground and headless modes. Recount consumers after U5 consolidation, then decide whether a physical boundary removes more complexity than it adds.
