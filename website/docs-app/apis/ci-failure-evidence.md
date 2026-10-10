# CI failure evidence

Failed ExUnit shards emit `aiur-test-failure` annotations with classification and exact test identity, capped at nine tests plus a truncation notice. `Aiur.CI.FailureDigest.build(sha)` reads Checks annotations and returns checks/URLs, tests, signature and `truncated`/`flake_only` flags.

Known flakes match the SHA-specific file or an open `flake` issue (whole line or Markdown code); `aiur init` provisions the label. Unknown reads, truncation and independent check errors are never flake-only. `aiur-derived-failure` names upstream checks: rollups are flake-only only when every named check is proven flake-only.

Signatures exclude proven flakes. ResourceStore caches completed evidence by SHA/check identities; reruns refresh and failed reads retry. Open flake issues are shared for 60 seconds. Reads use caller `ci_failure_digest`, never Actions logs; no quota saving is claimed.
