# U7 GitHub access seam: pre-merge candidate

Scope: clean integration candidate `0299daca28383a336682374e19e90d6434aa4e1a`, before the version PR and before merged-main or live acceptance. This is source and existing-test evidence, not a package extraction proof.

## Current ownership

- `Aiur.Application.child_specs/1` starts credential headroom, read cache, quota, broker timeout monitor, open-issue snapshot, durable resource store, agent cache bridge, publisher, mode registry and polling consumers in dependency order ([application](../../../../src/lib/aiur.ex)). The root supervisor uses `:rest_for_one`; moving one child changes its restart scope and startup contract.
- `Transport.default_request_fun/1` selects a credential before quota/cache admission. Its cache key assumes pooled credentials have the same repository visibility ([transport](../../../../src/lib/aiur/github/transport.ex)). A new facade or package cannot safely choose credentials later or add a second cache authority.
- `ResourceStore` joins webhook and poll observations by resource identity and retains validators and processed marks across restarts. On store failure it gives up reuse and suppression rather than claim a hit ([resource store](../../../../src/lib/aiur/github/resource_store.ex)). Moving only the reader would leave a second writer or state boundary behind.
- Headless and `--no-dashboard` remove terminal and dashboard children, respectively, while GitHub access owners remain in the always-on block. Existing shape tests cover those child choices and some ordering ([application tests](../../../../src/test/aiur/application_test.exs)).

## Existing check and decision

`cd src && mise exec -- mix test test/aiur/application_test.exs` passed 48/48 on the candidate. Those tests cover declared child ordering and run shapes; they do not crash GitHub children or prove durable state survives a proposed seam move. The current decision is to align outcomes in the existing `Transport`/`Client` path inside the process. There is no evidence yet that a physical package improves ownership, so package extraction stays conditional.

Before U7 can decide on extraction, test a cache, quota and resource-store restart under `:rest_for_one`; observe selected credential, budget accounting, cache fallback and durable resource identity before/after, in foreground and headless/no-dashboard release boots. Count all direct callers and compare dependencies after U5 consolidates access. Reject any extraction that introduces another credential selector, cache, supervisor or circular dependency. Repeat on merged main; this candidate is not the implementation base.
