# Directional, attenuable permission models for peer-to-peer gateway control

Scope: a fleet of 2-10 daemons ("gateways") that accept remote CLI calls from each other. Calls fall into six scope tiers: read status, message agents, manage agents, edit tickets/queues, edit config, administer trust. One human operator runs the fleet, and AI Executors hold credentials. The receiving gateway enforces every grant. A grant "A may do X to B" is independent of what B may do to A.

## Capability tokens: macaroons, Biscuit, UCAN (maturity and libraries)

### Takeaway
All three formats let a holder narrow a token offline and never widen it. That property directly addresses the requirement that "an Executor cannot grant itself more". The library picture for an Elixir + Node stack is thin. Biscuit is the most expressive and is maintained (Rust core, WASM for Node), but there is no Elixir binding on Hex. Macaroons have a small, stale Elixir package plus a Fly.io-specific one. UCAN 1.0 has JS libraries but no Elixir library. For 2-10 machines, a token format adds complexity without a matching benefit unless offline delegation between holders is a real need.

### Cited Findings
**Macaroons**
- Macaroons (NDSS 2014, Birgisson, Politz, Erlingsson, Taly, Vrable, Lentczner) are bearer credentials built from chained HMACs, "whose efficiency and ease-of-deployment equal that of Web cookies". They embed caveats that "attenuate and contextually confine when, where, by who, and for what purpose a target service should authorize requests" — [NDSS 2014](https://www.ndss-symposium.org/ndss2014/programme/macaroons-cookies-contextual-caveats-decentralized-authorization-cloud/); [paper PDF](https://www.ndss-symposium.org/wp-content/uploads/2017/09/04_3_1.pdf)
- Any holder can add a first-party caveat, which gives attenuation and delegation. A third-party caveat needs a "discharge" macaroon from another service, cryptographically bound to the caveat — [NDSS slides](https://www.ndss-symposium.org/wp-content/uploads/2017/09/04_3_slides.pdf); [superfly/macaroon Go docs](https://pkg.go.dev/github.com/superfly/macaroon@v0.2.13)
- Fly.io production lessons:
  - Every caveat must evaluate to true, and adding caveats can only weaken a token.
  - Tokens with no caveats should not be honored.
  - "We need things to be as rigidly unambiguous as they can be". They rejected untyped, opaque caveat strings and wrote their own typed Go implementation (SHA256, ChaCha20-Poly1305, MessagePack).
  - "Anyone who can verify a Macaroon can also mint one" (symmetric HMAC), so verification runs in an isolated service.
  - Revocation: each token has a nonce, and revoking it "cancels every token derived through attenuation by that nonce". "Revocation is rare, so just keeping a revocation list and invalidating caches wholesale seems fine."
  - "Pure restrictive caveats are an awkward way to express some roles."
  — [Fly.io, Macaroons Escalated Quickly](https://fly.io/blog/macaroons-escalated-quickly/)
- Fly.io expresses authentication as a third-party caveat discharged by its auth service. Its discharge tokens are short-lived (about 10.5 minutes), and users complain about that lifetime — [Operationalizing Macaroons](https://fly.io/blog/operationalizing-macaroons/); [Fly community thread](https://community.fly.io/t/how-to-create-attenuated-token-with-practical-validity-longer-than-10-min/26885)
- Elixir (checked against the Hex API on 2026-11-06):
  - `macaroon` 0.5.1 was last updated 2021-12-09, needs libsodium via enacl, and has 0.5.0 retired for a signature bug.
  - `macfly` 0.2.22 (updated 2026-07-31) is a "library for working with fly.io macaroon tokens", so it targets Fly's format.
  — [hex.pm macaroon](https://hex.pm/packages/macaroon); [hex.pm search API](https://hex.pm/api/packages?search=macaroon)
- Node: npm `macaroon` is at 3.0.4, last modified 2022-06-19 — [npm registry](https://registry.npmjs.org/macaroon)

**Biscuit**
- Biscuit is a public-key bearer token that supports offline attenuation and can be verified by anyone holding the root public key.
  - It is a chain of blocks. The authority block grants rights, and later blocks only add checks.
  - Its Datalog has facts, rules, `check if` / `check all` / `reject if`, and allow/deny policies. "There is no negation."
  - Third-party blocks are signed by an external party, which never sees the token.
  - Sealing prevents further attenuation.
  - Signatures are Ed25519 by default, with secp256r1 also supported.
  — [Biscuit specification](https://doc.biscuitsec.org/reference/specifications)
- Revocation: each block's signature is its revocation id, and "revoking a token should also revoke all derived tokens". The issuer should store the first block's revocation id with its expiry. "All tokens should come with an expiration date, to prevent the revocation list from growing indefinitely" — [Biscuit revocation guide](https://www.biscuitsec.org/docs/guides/revocation/)
- Implementations live in the eclipse-biscuit organization:
  - Rust, WASM, Python, and Haskell support spec v3.x.
  - Java supports v1, with v3.3 in progress.
  - Go supports v1.
  - .NET (third-party) supports v1.
  — [eclipse-biscuit/biscuit README](https://github.com/eclipse-biscuit/biscuit)
- Node: `@biscuit-auth/biscuit-wasm` latest is 0.6.0 (registry modified 2025-09-26). Node 18 needs a `globalThis.crypto` shim; Node 19+ does not — [npm registry](https://registry.npmjs.org/@biscuit-auth/biscuit-wasm); [npm page](https://npmjs.com/package/@biscuit-auth/biscuit-wasm)
- Elixir: a Hex search for "biscuit" returned no packages on 2026-11-06. Use would need a Rustler NIF over the `biscuit-auth` crate — [hex.pm search API](https://hex.pm/api/packages?search=biscuit); [docs.rs biscuit-auth](https://docs.rs/biscuit-auth/latest/biscuit_auth/)

**UCAN**
- The UCAN spec is v1.0.0. A capability is subject × command × policy. Commands are slash paths, and `/crypto` proves `/crypto/sign`.
  - Each delegation "MUST either directly restate or attenuate" its capabilities.
  - Delegation chains are checked offline.
  - Invocations must be unique to prevent replay.
  - Revocation is a last resort, because downstream sub-delegations may be unknown.
  - Principals are DIDs.
  — [ucan-wg/spec](https://github.com/ucan-wg/spec)
- Version 1.0 moved from JWT envelopes to IPLD/CBOR. The older `ts-ucan` is JWT-based. That comes from a secondary overview, not a primary source — [UCAN specs overview (secondary)](https://cdn.jsdelivr.net/npm/@wovin/core@0.3.3/src/pubsub/UCAN%20Specs%20Overview.md); [ucan-wg/ts-ucan](https://www.github.com/ucan-wg/ts-ucan)
- Node: `iso-ucan` 3.0.0 was modified 2026-10-27, and `@ucanto/core` 10.4.6 was modified 2025-10-27. Elixir: no Hex package found — [npm iso-ucan](https://registry.npmjs.org/iso-ucan); [npm @ucanto/core](https://registry.npmjs.org/@ucanto/core); [hex.pm search](https://hex.pm/api/packages?search=ucan)

### Inferences
- Macaroons use a symmetric key, so each receiving gateway would have to hold the minting key. That is acceptable only when the receiver mints its own inbound tokens. That model matches "B decides what A may do to B" well: B mints, B verifies, and A can only attenuate.
- Biscuit and UCAN use public keys, so a central authority (the operator) can mint for any receiver without sharing secrets. That fits better if the human operator's key must be the root of trust.
- Attenuation only stops widening a token you already hold. It does not stop an Executor from calling a "grant" endpoint that mints a new, wider token. That control belongs to the trust-administration scope (see below), whatever the token format.
- With no Elixir library for Biscuit or UCAN, adopting either means owning a NIF or a re-implementation. For 2-10 machines, that cost is probably larger than the benefit.

### Gaps
- Did not verify whether `macfly` can mint and verify generic (non-Fly) macaroons.
- Did not find a primary-source list of UCAN 1.0 implementations or an interoperability test suite status.
- No Biscuit maintenance cadence data (release dates) beyond the npm modified date.

## Simpler alternatives and how existing systems model "who may do what"

### Takeaway
Every mature system surveyed uses the same shape: an identity, a set of policies keyed on that identity, evaluated deny-by-default by the receiving side. Tailscale grants are directional (src → dst) and carry opaque app capabilities that the destination application reads and enforces itself. That is the closest off-the-shelf analogue to "gateway A may do X to gateway B". A per-peer grant table on each receiver is the simplest design that meets the requirement.

### Cited Findings
- **Tailscale grants**:
  - Grants define "which source devices (`src`) can access which destination devices (`dst`)". They are deny-by-default.
  - The `ip` field controls network access. The `app` field carries application capabilities named `domain/capabilityName`, whose parameters are "opaque JSON objects" to Tailscale.
  - The destination app reads them via LocalAPI ("usually a better choice"), `tsnet`, `tailscale whois` (for debugging), or a header forwarded by `tailscale serve`.
  - First-party examples include `tailscale.com/cap/drive`, `cap/kubernetes`, `cap/secrets` (setec), `cap/tailsql`, and `cap/golink`.
  — [Tailscale grants](https://tailscale.com/kb/1324/grants); [Grants app capabilities](https://tailscale.com/kb/1537/grants-app-capabilities)
- Tailscale device posture checks apply only to the grant's `src`, not its `dst` — [Tailscale grants](https://tailscale.com/kb/1324/grants)
- **Nomad ACLs**:
  - Tokens map to policies written in HCL.
  - Dispositions are `read`, `write`, `deny`, and `list` (for plugins), with fine-grained capabilities such as `submit-job`, `read-logs`, `alloc-exec`, and `scale-job`.
  - "Deny takes precedence when multiple policies are associated with a token."
  - Rules are split by surface: namespace, node, agent, operator, quota, host_volume, plugin.
  — [Nomad ACL policies](https://developer.hashicorp.com/nomad/docs/secure/acl/policies)
- **Kubernetes RBAC**:
  - "Permissions are purely additive (there are no 'deny' rules)" — [K8s RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
  - The good-practices page says: avoid wildcards, because they also grant "all object types which are created in the future". `system:masters` "bypasses all RBAC rights checks" and "cannot be revoked by removing RoleBindings". Being able to create workloads implicitly grants any service account's rights in that namespace — [K8s RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- **OpenSSH certificates**:
  - Principals (`-n`) and a validity window (`-V`) bound the certificate.
  - Critical options (`force-command`, `source-address`, `verify-required`) must be enforced, and "unknown critical options will cause the certificate to be refused". Extensions, by contrast, may be ignored.
  - `clear` drops default permissions so that only the listed ones remain.
  - Revocation uses KRLs by serial (`-z`, ranges allowed) or by key ID (`-I`, which the server logs on authentication).
  — [ssh-keygen(1) CERTIFICATES](https://man.openbsd.org/ssh-keygen#CERTIFICATES)

### Inferences
- A suitable minimal model is a per-receiver file or table: `peer_id → [scopes]`, plus optional per-scope constraints such as agent or queue name. Peer identity comes from mTLS, a pinned Ed25519 key, or a Tailscale node identity. A missing entry means deny. That is the Tailscale/Nomad pattern, scaled down.
- Fail closed on unknown fields, like SSH critical options. A receiver should refuse any grant or constraint it does not understand, so that an older gateway does not silently widen an access.
- Avoid wildcard scopes such as `*`. Tiers added later (for example, a future "delete workspace") would otherwise be granted silently, which is the Kubernetes warning.
- Watch for implicit escalation through scopes that look harmless, as with K8s pod-creation. "Edit config" or "manage agents" can reach trust indirectly, for example a config key that lists trusted peers, or an agent whose environment holds a credential. Classify any such scope as trust administration.
- Using Tailscale app capabilities would move policy authority to the tailnet admin console. That works only when every gateway is on Tailscale, and it adds an external dependency. A locally held table keeps the receiver as the single authority.

### Gaps
- I did not read the Kubernetes "Privilege escalation prevention" section verbatim; the fetch was truncated. As commonly documented, it says you may create or bind a role only if you already hold its permissions, unless you have the `escalate` or `bind` verb. Confirm the wording before you quote it.
- Did not fetch the Nomad token types (management vs client) page.

## Preventing self-elevation

### Takeaway
Treat "administer trust" as a separate, non-delegable tier. No token or peer grant may confer it remotely. Changes to it need the human operator's out-of-band confirmation, and every change is audited. Use the Kubernetes rule: a principal cannot grant what it does not hold. Then add a stronger rule: a remote principal can never grant at all.

### Cited Findings
- K8s RBAC treats `escalate`, `bind`, and `impersonate` as dangerous. They are not quoted verbatim here (see the Gaps above). The good-practices page recommends low-privileged accounts with impersonation instead of daily use of `cluster-admin` — [K8s RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- Biscuit, macaroons, and UCAN all allow attenuation only. UCAN states that each delegation "MUST either directly restate or attenuate" — [ucan-wg/spec](https://github.com/ucan-wg/spec); [Fly.io](https://fly.io/blog/macaroons-escalated-quickly/)
- Third-party caveats (macaroons) and third-party blocks (Biscuit) can require a discharge from an approval service. Fly.io names "approvals" and SSO as examples of plugging in external checks — [Fly.io](https://fly.io/blog/macaroons-escalated-quickly/); [Biscuit spec](https://doc.biscuitsec.org/reference/specifications)
- OpenSSH `verify-required` forces user verification (a PIN or touch on a FIDO key) for a certificate — [ssh-keygen(1)](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
- The Nomad, K8s, and Tailscale models each keep ACL/policy management as a separately grantable surface (Nomad's `operator` and ACL rules, K8s `rbac.authorization.k8s.io` verbs, Tailscale's admin-only policy file) — [Nomad](https://developer.hashicorp.com/nomad/docs/secure/acl/policies); [K8s RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/); [Tailscale grants](https://tailscale.com/kb/1324/grants)

### Inferences
- Recommended rules (design synthesis, not from one source):
  1. The `trust:admin` scope never appears in a grant table entry for a remote peer. Trust changes are accepted only from a local operator session, such as a CLI on the receiving host or a loopback/Unix socket.
  2. A remote request may at most *propose* a trust change. The receiver queues it, and it takes effect only after the human confirms out of band. Out-of-band means a different channel from the one the Executor controls, for example a push approval, a TOTP, or a FIDO touch. An Executor credential alone can never complete it.
  3. A grant-issuing endpoint must check "requested ⊆ caller's own scopes ∖ {trust:admin}" (the K8s no-escalation rule), even for operator tools that Executors can reach.
  4. Executor credentials are distinct principals (`executor@A`), never the same token as the human's (`operator@A`). The audit log can then tell them apart, and the receiver can deny `trust:admin` and `config:edit` to Executors by principal type.
  5. Config that controls trust (peer lists, grant tables, keys) must live outside the "edit config" scope, or that scope becomes trust administration by another route.
- A human confirmation step is only as strong as its channel. If the Executor can read the TOTP seed or reach the approval UI with the same credential, it is not a second factor.

### Gaps
- Found no primary-source standard for "human-in-the-loop approval of AI-agent privilege grants". Rules 1-5 are a synthesis.

## Revocation, rotation, replay protection, idempotency, and audit

### Takeaway
At 2-10 machines, short-lived credentials plus a small deny list (by token or serial id) on each receiver cover revocation. Every remote write should carry a request id or an Idempotency-Key, which the receiver stores for about 24 hours with a payload fingerprint. The audit log records origin peer, actor principal, scope used, request id, and outcome, and only the daemon writes it.

### Cited Findings
- **Revocation lists work at scale only with expiry.** Biscuit: "All tokens should come with an expiration date, to prevent the revocation list from growing indefinitely". Revoking the first block's id kills all derived tokens — [Biscuit revocation](https://www.biscuitsec.org/docs/guides/revocation/). Fly.io keeps a revocation list keyed by nonce and invalidates caches wholesale — [Fly.io](https://fly.io/blog/macaroons-escalated-quickly/). OpenSSH KRLs revoke by serial (ranges, about 1 bit each) or by key ID — [ssh-keygen(1)](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
- **Refresh-token reuse as a theft signal.** If a single-use refresh token is reused, revoke all of that client's tokens — [Biscuit revocation](https://www.biscuitsec.org/docs/guides/revocation/)
- **Idempotency-Key, IETF draft-ietf-httpapi-idempotency-key-header-08.** The datatracker lists it dated 22 Oct 2026, expiring 25 Apr 2027, Standards Track, and still a draft.
  - The value is a String.
  - It "MUST be unique and MUST NOT be reused with another request with a different request payload". A UUID is recommended.
  - The resource may compute a fingerprint.
  - Errors: 400 when the key is missing, 422 when a key is reused with a different payload, 409 while the original request is still in flight.
  - Expiry policy is up to the resource and must be published.
  — [IETF datatracker](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/)
- **Stripe (v1 API).**
  - Keys are up to 255 characters, and V4 UUIDs are recommended.
  - Stripe saves the status code and body once execution begins, so a 500 is replayed too.
  - Keys may be pruned after 24 hours.
  - Parameters are compared to the original request, and a mismatch is an error.
  - Validation failures and concurrent conflicts are not saved, so the client can retry them.
  - Keys apply to POST only.
  — [Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)
- **UCAN invocations must be unique to prevent replay** — [ucan-wg/spec](https://github.com/ucan-wg/spec)
- **SSH certificate key IDs are logged by the server on each authentication**, which ties an audit record to the credential — [ssh-keygen(1)](https://man.openbsd.org/ssh-keygen#CERTIFICATES)

### Inferences
- **Replay window.** Require a client timestamp within ±N s plus a request id (nonce) that the receiver remembers for longer than N. That rejects captured-request replay without per-session state. Make the idempotency key and request id the same field to keep the protocol small. Over mTLS or WireGuard (Tailscale), network replay is already prevented, so the nonce mostly guards against application-level duplicates and retries.
- **Rotation at this scale.** Use short credential TTLs (hours to days) issued by the operator, with an overlap window that accepts the current and previous key. Revoke by deleting the peer's grant row. That is immediate, because the receiver checks its own table on every call, so no distributed revocation list is needed when the receiver is the authority.
- **Audit record per remote call.** Record receiver, origin gateway id, actor principal (operator vs Executor and which one), credential id/serial, scope exercised, target, request/idempotency id, outcome (allowed, denied and reason, replayed), and timestamp. Write it outside any agent-writable path. Log denials too, because a denial is the signal of an attempted self-elevation.
- **Apply idempotency to all write tiers** (message, manage, edit tickets/queues, edit config). Read-status does not need it.

### Gaps
- No primary source fetched on HTTP Message Signatures (RFC 9421), which is an alternative way to bind a request id and timestamp to a signature.

## Recommended default trust posture for newly registered peers

### Takeaway
A newly registered peer should receive nothing by default, or at most `status:read` toward the receiver. Every higher tier is an explicit, operator-confirmed, per-direction grant. A grant from A to B never implies the reverse grant. `trust:admin` is never granted to a remote peer.

### Cited Findings
- Tailscale grants are "deny-by-default". The direction is explicit (src → dst) — [Tailscale grants](https://tailscale.com/kb/1324/grants); [app capabilities](https://tailscale.com/kb/1537/grants-app-capabilities)
- K8s RBAC has no deny rules, so ungranted means refused. It recommends the narrowest scope and no wildcards — [K8s RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/); [good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- OpenSSH `clear` removes all default permissions so that only explicitly listed ones apply. Certificates are valid "forever" unless `-V` is set, which is a default to override — [ssh-keygen(1)](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
- Fly.io: "Tokens with no caveats should not be honored", meaning an unconstrained credential is treated as invalid rather than all-powerful — [Fly.io](https://fly.io/blog/macaroons-escalated-quickly/)

### Inferences
- Suggested enrollment default:
  - The peer's identity is pinned (key fingerprint) after human confirmation of a pairing code.
  - Inbound grants on the receiver: none, or `status:read` only.
  - The grant expires (for example, 30 days) unless renewed.
  - Grants are listed per direction in each receiver's own table.
  - Promotion to `agents:message` → `agents:manage` → `tickets:edit` → `config:edit` is an explicit operator action on the receiving host, and each step is audited.
  - `trust:admin` cannot be granted to a remote peer.
- Symmetric "pairing" UX is fine for identity exchange. Authorization must still be recorded separately per direction, so pairing never implies mutual write access.

### Gaps
- Found no published default-posture guidance written specifically for small peer-to-peer daemon fleets. The posture above is extrapolated from the systems cited.
