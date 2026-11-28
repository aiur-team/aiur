# GitHub access Mix promotion record

**No-go as of 2026-11-26.** Keep the Elixir library in `src/` and the
standalone wrapper in `packages/gh-access/`. The
[promotion test](../migration-plan.md#5-promotion-test-when-a-logical-component-becomes-a-physical-package)
requires all five criteria to pass. This assessment uses main revision
`16949f33e00cfeac31bd4dc72d028d9f29879fce` and the
[ticket plan](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/github-access/plan-gha-6-promotion.md).

## 1. Two consecutive releases with zero allowlisted violations

**Unmet.** The latest two stable Aiur releases were
[v0.0.7](https://github.com/aiur-team/aiur/releases/tag/v0.0.7)
(`465aca643527ea94a4d0d6d7c178c5d23d2aaf57`) and
[v0.0.8](https://github.com/aiur-team/aiur/releases/tag/v0.0.8)
(`ed43c0e9442c46b9c2000ca23bddf40c13d2efb4`). At each tag,
`git -C "$workspace" ls-tree -r --name-only <tag> -- components/github-access.json scripts/components/allowlist/github-access.tsv scripts/check-components.py`
printed no paths. The [boundary landed in #5030](https://github.com/aiur-team/aiur/pull/5030).
Two tags without a component boundary cannot establish its exemption count.
Image nightlies are prereleases and were excluded from the stable release pair.

On the audited revision, the report command below exited 0. The report
header was followed by zero rows, so there were zero inbound or outbound
allowlist entries, live or stale, in this snapshot. This covers the whole
allowlist, including exemptions in other components targeting GitHub access.

```text
$ mise exec -- python3 scripts/check-components.py --report --component github-access --require-elixir
[reference and cycle summaries omitted]
components: promotion debt for github-access:
direction  rule  source component  target module  status
```

## 2. Component-declared children and preserved boot order

**Unmet.** The [access facade](../../../../../../src/lib/aiur/github/access.ex)
provides eight individual child spec delegates. The
[composition root](../../../../../../src/lib/aiur/application/children.ex)
chooses and orders AppTokenRefresher, CredentialHeadroom, ReadCache, Quota,
BrokerTimeout, BudgetBroker, ResourceStore and AgentCacheBridge itself.
Other children, including HoldPressure and OpenIssueSnapshot, interleave with
these specs. [The root supervision strategy](../../../../../../src/lib/aiur.ex)
is `:rest_for_one`, so the exact positions affect restart behavior. The
[literal order fixture](../../../../../../src/test/aiur/application_child_order_test.exs)
defines the baseline for a future component-owned `child_specs(settings)`
contract.

## 3. Isolated access tests and portable durable state

**Unmet.** [Static settings](../../../../../../src/lib/aiur/github/access/settings.ex)
support a caller-supplied root. The
[settings consumer tests](../../../../../../src/test/aiur/github/access/static_settings_consumers_test.exs)
cover injected state and service ports under the core test project. For
example, the resource-store case can reuse the running singleton, and the
budget lease notification case uses the broker bypass path.
`git -C "$workspace" ls-tree -r --name-only HEAD -- packages/elixir/aiur_github_access`
printed no paths at the audited revision. The
[core Mix project](../../../../../../src/mix.exs) declares
`Aiur.Application` and has no GitHub access path dependency. Package-local
`mix test` without the Aiur boot and portability of the access state and
recovery code remain to be demonstrated.

## 4. Manifest ownership

**Unmet.** The [GitHub access manifest](../../../../../../components/github-access.json)
lists credential and budget environment variables in `owns.env`.
`owns.config` and `owns.state` are both empty. The
[core settings adapter](../../../../../../src/lib/aiur/github/access_settings.ex)
reads access settings from the shared `tracker.github` and `agent` schema
sections, including credential pools and broker timeout settings. It also
resolves the budget directory, per-repo quota directory and
`github_resources.json`. Declare ownership for the access-specific settings
and durable paths in the manifest while keeping the shared schema embeds in
core.

## 5. Second consumer or independent release

**Unmet for the Elixir library.** The [standalone wrapper](../../../../../../packages/gh-access/README.md)
uses the [shared broker and answer-store contract](../../../../../../website/docs-app/apis/gh-access.md)
from shell and Python. Its build has no Mix library dependency. The
[design's Q1](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/github-access/brainstorm.md#9-open-questions-for-kevin)
lists Khala as a possible consumer if it reads GitHub. The reviewed design and
issue records identify neither a committed Elixir consumer nor an explicit
need from Kevin to release the library independently.

## Follow-up

[Follow-up #8125](https://github.com/aiur-team/aiur/issues/8125) tracks all five
criteria. Recheck on **2026-12-28**, or earlier when both qualifying releases
and the consumer or independent-release evidence are available. The earlier harness
precedent [#5475](https://github.com/aiur-team/aiur/pull/5475) also recorded
a no-go. If GitHub access later passes, the existing
[voice Mix path dependencies](../../../../../../src/mix.exs) provide in-tree
packaging examples.
