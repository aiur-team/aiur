# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
admission_resource=$resource
# Identity derivation needs the command's admission decision (resource /
# admission_required), which the classification above just made — so it runs
# here, not at the top of the script, and only for a call that is about to be
# admitted against a metered pool (`budget_derive_identity` re-checks the same
# gates). A local `auth token`/`config` read never pays a GitHub round trip.
budget_derive_identity
# `none` is the shared EndpointPolicy table's pool for endpoints GitHub does
# not meter (`/rate_limit`). They are admitted for ordering but their ledger
# row keeps `resource: none` — the same row the daemon's Budget path writes —
# rather than being booked onto the core bucket, so the guard and the daemon
# cannot disagree about what rate-limit probes cost (#2353). No `none`->core
# mapping is applied: the only admitted `none`-resource command is `api
# rate_limit`, and non-admitted `none` commands (config/auth token) never
# reach the broker.
