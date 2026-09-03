---
title: Organization Repository 404 Diagnostics - Plan
type: fix
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Organization Repository 404 Diagnostics - Plan

## Goal Capsule

Make GitHub repository authorization failures actionable without weakening true missing-branch detection. The issue contract and GitHub's documented REST semantics are authoritative. Stop if the implementation would expose credential material or require broader token permissions. This ticket owns implementation, tests, documentation, draft PR self-review, and CI handoff.

## Product Contract

### Summary

Aiur will distinguish a real missing base branch from GitHub's authorization-masked `404 Not Found` for an organization-owned repository and will explain the likely remediation during `aiur init`.

### Problem Frame

CI readiness currently checks the branch endpoint before the repository endpoint. GitHub deliberately returns 404 for inaccessible private resources, so an unauthorized organization token is confidently misreported as a missing configured branch and the wizard offers irrelevant CI setup.

### Requirements

- R1. A repository-scoped 404 must not prove that the configured base branch is absent unless the same credential can read repository metadata.
- R2. When the repository is unreadable but its owner resolves as an organization, diagnostics must identify the token type from its prefix and give matching remediation.
- R3. Diagnostics must explain that `gh` may succeed with a different keyring credential while Aiur's configured token fails, without logging token material.
- R4. `aiur init` must surface repository authorization failure before offering workflows, rulesets, labels, or other setup that cannot repair access.
- R5. User-owned or unclassifiable repository 404s must remain honest access-or-absence errors rather than being mislabeled as organization authorization.

### Acceptance Examples

- AE1. Given readable repository metadata and a 404 for `branches/main`, readiness reports `base_branch_missing`.
- AE2. Given a 404 for repository metadata and a readable organization owner, readiness returns an organization-access diagnostic and never requests the branch endpoint.
- AE3. Given AE2 with `ghp_`, `github_pat_`, or `gho_` credentials, init names classic PAT, fine-grained PAT, or OAuth token respectively and renders the relevant recovery path.

## Planning Contract

### Key Technical Decisions

- KTD1. Pin one resolved credential for the complete readiness inspection, then fetch repository metadata before checking the configured branch. This prevents credential-pool reselection from comparing visibility across different identities and preserves `base_branch_missing` only after the same credential establishes repository visibility.
- KTD2. Probe `GET /orgs/{owner}` only after repository metadata returns 404. A successful organization lookup supports organization-specific guidance; any other result retains a generic ambiguous repository-access error.
- KTD3. Carry a safe token-kind atom in the error detail, derived only from the pinned credential's documented prefix. Formatting remains outside the transport path and never includes token contents.
- KTD4. Keep the richer diagnostic in CI readiness and format it for the init surface, rather than adding a second independent repository probe to the wizard.

### Assumptions

- Organization profile lookup is sufficient positive evidence that the configured owner is an organization; failure to prove that fact falls back to generic guidance.
- The extra owner request occurs only on repository 404s, so normal readiness cost and request order remain bounded.

## Implementation Units

### U1. Disambiguate repository and branch 404s

**Goal:** Establish repository visibility before classifying branch absence and return a safe organization-access error when the owner probe succeeds.

**Requirements:** R1, R2, R5; AE1, AE2.

**Dependencies:** None.

**Files:** `src/lib/aiur/github/ci_readiness.ex`, `src/lib/aiur/github/credential_selector.ex`, `src/test/aiur/github/ci_readiness_test.exs`, `src/test/aiur/github/credential_selector_test.exs`.

**Approach:** Mark every request in one readiness inspection as credential-pinned so the transport bypasses pool reselection, reorder the existing metadata and branch reads, classify the pinned token's prefix without retaining the credential, and add the organization lookup only to the repository-404 path. Preserve existing structured transport errors when repository or owner requests fail for reasons other than 404.

**Test scenarios:**

1. Covers AE1. Repository metadata succeeds and branch lookup returns 404; the result contains only `base_branch_missing`.
2. Covers AE2. Repository metadata returns 404 and the owner organization lookup succeeds; the returned error contains repository, organization, and classic-PAT kind, and no branch request occurs.
3. Repository metadata and owner lookup both return 404; the result remains a generic HTTP 404 rather than claiming either branch absence or organization ownership.
4. Token-prefix classification covers classic PAT, fine-grained PAT, OAuth, installation, and unknown credentials without returning the credential itself.
5. With two configured credentials, every request in one readiness inspection sends the originally resolved token and the resulting diagnostic names that same token's kind.

**Verification:** Request capture proves repository-first ordering and proves no branch/config reads occur after repository access fails.

### U2. Render actionable init guidance and document the behavior

**Goal:** Explain the ambiguous GitHub 404 and token-specific recovery before init performs irrelevant setup.

**Requirements:** R2, R3, R4; AE3.

**Dependencies:** U1.

**Files:** `src/lib/aiur/init/github.ex`, `src/test/aiur/init/github_test.exs`, `website/docs-app/apis/github.md`, `website/docs-app/reference/cli.md`.

**Approach:** Add one formatter branch for the structured organization-access error. Classic PAT guidance covers `repo` plus SAML SSO authorization; fine-grained PAT guidance covers organization resource ownership and approval; OAuth and App tokens receive credential-appropriate authorization guidance. Mention the separate `gh` keyring credential where it resolves the observed contradiction.

**Test scenarios:**

1. Covers AE3. Each known token kind produces its name and unique remediation in the init error.
2. Unknown tokens receive accurate generic organization authorization guidance.
3. No diagnostic contains a token-shaped sentinel.
4. The init failure path returns before CI scaffolding or label setup is offered.

**Verification:** Init adapter tests assert the operator-visible wording and documentation describes both 404 ambiguity and credential-source mismatch.

## Risks & Dependencies

- GitHub may return 404 for both absent and unauthorized resources. Mitigation: only report a missing branch after repository metadata succeeds, and only name organization ownership after a positive owner probe.
- Token prefixes identify credential type, not whether the credential has the required grant. Mitigation: wording says authorization is likely and gives checks rather than asserting the exact missing permission.
- Repository metadata is a cached auth-preflight probe. Reordering must preserve its existing caller attribution and avoid adding successful-path requests.

## Sources & Research

- `src/lib/aiur/github/ci_readiness.ex` contains the current branch-first request sequence and repository metadata request.
- `src/lib/aiur/init/github.ex` owns the operator-facing readiness failure and CI-scaffold boundary.
- GitHub's REST troubleshooting guide documents that inaccessible private resources return 404 instead of 403 to avoid confirming existence.
- GitHub's authentication and PAT documentation defines `ghp_`, `github_pat_`, `gho_`, and `ghs_` token prefixes, classic PAT SSO authorization, fine-grained PAT resource ownership, and organization approval.

## Verification Contract

- The touched modules compile with warnings as errors and remain formatted.
- Every affected test selected by the repository helper runs with bounded parallelism.
- Each new regression test fails when its corresponding production behavior is removed, in an isolated worktree.
- Documentation accurately distinguishes Aiur's resolved credential from a potentially different `gh` keyring credential.

## Definition of Done

- R1-R5 and AE1-AE3 are covered by focused tests.
- Existing missing-branch and readiness behavior remains green.
- Required GitHub API and CLI documentation ships in the same PR.
- No raw token is returned, rendered, logged, or stored in readiness results.
- The draft PR is self-reviewed against its claims, current with `main`, and contains no abandoned implementation.
