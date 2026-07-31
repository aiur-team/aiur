# Daemon token posture

The daemon must use a GitHub App installation token, rather than a personal
access token. Installation tokens identify the machine integration, are scoped
to an installation's repositories, and expire after roughly one hour.

The App must be granted only:

- Contents: read and write
- Issues: read and write
- Pull requests: read and write

It must not receive Administration, Actions, Secrets, or Workflows permission.
Token issuance, refresh, and client migration are tracked by #1375, alongside
the rate-limit work in #678. This ticket deliberately records the posture and
does not broaden the merge-boundary change into an authentication migration.

The CI ruleset audit is deliberately separate from the daemon. Its
isolated `RULESET_AUDITOR_TOKEN` secret needs repository Administration: write
visibility because GitHub otherwise omits `bypass_actors` from ruleset GET
responses. The audit workflow performs only read operations and receives the
credential only on trusted pushes to protected branches, but the credential's
capability means it must not be reused as the daemon token. The daemon remains
forbidden from receiving Administration, Actions, Secrets, or Workflows
permission.
