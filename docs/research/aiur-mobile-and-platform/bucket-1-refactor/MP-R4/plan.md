---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
feature_id: MP-R4
bucket: 1-refactor
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: ../../owner-design-tasks/DESIGN-R4.md
feeds_research_question: MP-Q2 (push relay; designed by MP-N4, not here)
---

# MP-R4 — The `hooks.aiur.dev` relay: confirm the inbound boundary, feed MP-Q2

- **U0 gate (X-58, RC-19).** Every MP-R4 ticket waits for U0 review of the prior plan
  (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps
  that gate for refactor work. U0 has no ticket ID, so the gate is stated here and not in
  `blocked_by`; the MP-R1-C11-T02 recheck does not replace it.

## Summary

The "Cloudflare/GitHub App relay" is **an inbound GitHub-webhook tunnel and
nothing else**:

- the domain is `hooks.aiur.dev`;
- it runs on the operator's own host;
- it is a `cloudflared` named tunnel, path-scoped to `/api/v1/github/webhook`.

The repository has **no relay code**. The provider boundary the brief asks for
already exists, and it is protocol-shaped rather than vendor-shaped. Aiur
exposes one HMAC-verified HTTP route and treats any ingress that can forward
an HTTPS POST to it as interchangeable.

The GitHub App is a separate thing: it is the daemon's API identity, unrelated
to the tunnel.

MP-R4 is a **confirmation and documentation feature**:

- one docs chunk;
- one fact sheet for MP-Q2;
- no runtime change;
- no new abstraction.

Building an outbound "relay provider" interface here would be speculative.
MP-N4 designs push, and nothing in the inbound tunnel is reusable for it apart
from operational patterns.

Prior-units: U5 (GitHub outcomes; `website/docs-app/apis/github.md` is its
cited doc). Prior-boundaries: `ING` #9, `GHC` #5. Prior-features:
`integrations-25` (keep webhook ingress), `config-12`. Size-owner:
`website/docs-app/apis/github.md` is 760 lines (Phase C recount; the section starts at line 742), assigned to `DOCS` (U8 split
pending), so a doc edit must not grow it without that owner's split.

## 1. Repository findings (verified at `45a290e3`)

These extend `baseline/capability-baseline-bucket-1.md` § R4.

### 1.1 What exists in code

- **Receiver:**
  - The route is `post "/api/v1/github/webhook"` under the `:github_webhook`
    pipeline (`src/lib/aiur_web/router.ex:69-75`). It is placed first, so the
    dashboard catch-all cannot claim it.
  - The path constant is in `src/lib/aiur_web/github_webhook.ex:12`. The body
    cap is 25 MB (`:17`).
  - Auth is `AiurWeb.GithubWebhook.Auth` (`src/lib/aiur_web/github_webhook/auth.ex`).
    - The secret is read from `AIUR_GITHUB_WEBHOOK_SECRET` **on every request**
      (`:26`, `:71-79`), so it rotates without a restart.
    - A blank or unset secret means 401 plus a throttled alert,
      `system.github_webhook.secret_missing` (`:81-110`).
    - Signatures are checked by `GithubWebhook.Signature`: HMAC-SHA256 over the
      raw body.
- **Provider-neutral delivery seam:**
  - `Aiur.Webhooks.EventSource` (`src/lib/aiur/webhooks/event_source.ex`) is a
    `@callback deliver/3` with `Polling` and `Webhook` implementations.
  - Its moduledoc says consumers "must be unable to tell which mode a repo is
    in".
  - A shared consumer suite enforces equivalence
    (`src/test/aiur/webhooks/consumer_equivalence_test.exs`).
  - This is the existing replaceable boundary. Polling is the
    always-available provider, and the webhook is an optional accelerator.
- **Configuration:** `Aiur.Config.Schema.Webhooks`
  (`src/lib/aiur/config/schema/webhooks.ex:7-27`):
  - `repos` (default `[]`)
  - `silence_threshold_seconds` (900)
  - `sweep_interval_seconds` (60)
  - `poll_widen_factor` (2.0)
- **Visibility:** per-repo delivery mode reaches the CLI through
  `Aiur.Webhooks.ModePresenter.rows/0` (`src/lib/aiur/agent_control_cli.ex:2302`).
- **No proxy coupling:** `src/lib/aiur_web` has no `X-Forwarded-*`,
  `CF-Connecting-IP` or `remote_ip` handling. Aiur does not know or care which
  ingress carried a delivery.
- **GitHub App** (independent of the tunnel):
  - Code: `src/lib/aiur/github/{app_credentials,app_token,app_token_refresher}.ex`.
  - Env: `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and one of
    `GITHUB_APP_PRIVATE_KEY_PATH` / `GITHUB_APP_PRIVATE_KEY`
    (`src/lib/aiur/env/schema.ex:79-84`, `:147-151`).
  - The App authenticates the daemon's *outgoing* GitHub API calls. The
    webhook may be configured as an App webhook or a repo webhook; Aiur only
    sees signed POSTs either way (`apis/github.md` § Optional webhook).

### 1.2 What does not exist

A search at the base SHA (baseline § R4, re-run here) for
`hooks.aiur.dev|cloudflare|cloudflared` outside docs found:

- marketing lines only (`README.md:41`, `packaging/npm/aiur-cli/README.md:41`);
- no Workers code;
- no `wrangler` config;
- no tunnel config.

The repository has no outbound relay, no device fan-out, no push credentials
and no client authentication through the tunnel.

### 1.3 Original purpose (from `website/docs-app/apis/github.md`)

The purpose was poll latency and GitHub API budget:

- A proven webhook widens polling by `poll_widen_factor`.
- It raises `ReadCache` TTLs from 30 s to 1 h.
- It wakes dispatch on actionable deliveries.

The Cloudflare boundary section (`apis/github.md:742-760`) states: "Cloudflare
is transport for the GitHub webhook, not an API Aiur calls". It names two
independent locks: path-only tunnel routing and the HMAC signature.

### 1.4 Operator-host facts (not product behaviour)

These are labelled **[host]** in the baseline:

- `~/.cloudflared/config.yml` routes only `^/api/v1/github/webhook$` to the
  daemon, then a catch-all `http_status:404`.
- The tunnel runs as `cloudflared-aiur-webhook.service`.
- The dogfood config binds `0.0.0.0:4000`.

R4 does not change any of these.

## 2. Proposed boundary

The boundary is already in place, and R4 only names it:

| Layer | Owner | Replaceable by |
| --- | --- | --- |
| Public ingress (TLS, hostname, forwarding) | Operator infrastructure, outside the repo | Any HTTPS ingress that forwards **only** the webhook path: a `cloudflared` named or quick tunnel, or another reverse proxy. Aiur has no vendor code to swap. |
| Delivery authentication | `AiurWeb.GithubWebhook.Auth` + `Signature` | Fixed: GitHub's `X-Hub-Signature-256` contract. |
| Transport equivalence | `Aiur.Webhooks.EventSource` (`Polling` / `Webhook`) | Polling is the mandatory fallback; the webhook is optional. |
| API identity | `Aiur.GitHub.App*` or `GITHUB_TOKEN` | Independent of ingress. |

The rule R4 records: **no Aiur feature may require a specific ingress vendor,
the owner's domain, or a public ingress at all.** Today polling satisfies that
(`optional-optimizations.md` § What you lose: "Polling is the default
fallback").

## 3. Alternatives

| Option | Verdict |
| --- | --- |
| A. Add an `Aiur.Relay` behaviour now (inbound and outbound) for future push | **Rejected.** There is no second implementation and no outbound caller, so it is speculative. MP-N4 owns the push transport and will define its own provider port with real requirements. |
| B. Put tunnel management in Aiur (spawn `cloudflared`) | Rejected. It would make Cloudflare a product dependency, which contradicts the brief. |
| C. Widen the existing tunnel to carry mobile traffic | **Rejected.** It breaks the "path-only" lock (`apis/github.md:760`, "a host-wide tunnel would expose" the dashboard) and makes private agent endpoints publicly routable. |
| **D. Confirm, document the boundary and "what the ingress sees", and hand MP-Q2 the facts** | **Recommended.** |

## 4. Facts for MP-Q2 (inputs only; MP-N4 designs)

1. **The tunnel is inbound-only.** `cloudflared` dials out to Cloudflare and
   then carries requests *into* the daemon. Cloudflare's docs say:
   "cloudflared initiates an outbound connection through your firewall from
   the origin to the Cloudflare global network". Source:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/,
   accessed 2026-10-06, no version on the page.

   Push needs the opposite direction: daemon → relay → APNs/FCM → device. No
   existing code path sends anything through the tunnel.
2. **What the current ingress sees.** Requests traverse Cloudflare's network
   ("each connector sends traffic to the nearest Cloudflare data center", same
   source). Whether Cloudflare sees the webhook body in plaintext depends on
   TLS termination at its edge. That is **unverified**; R4-RQ1 below confirms
   it with a source. For push, MP-N4 must assume any operator of a relay hop
   sees routing metadata, and plaintext unless the payload is end-to-end
   encrypted.
3. **Push credentials belong to the app publisher, not the self-hoster.**
   - APNs token auth uses "an APNs authentication token signing key … from
     your developer account". The issuer is "the 10-character Team ID".
   - "APNs relates a team ID and associated bundle IDs to a connection".
   - Source: https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
     (read via the JSON doc endpoint), accessed 2026-10-06.
   - FCM HTTP v1 needs a Google service account of the Firebase project, which
     mints OAuth 2.0 bearer tokens. A service account from another project can
     send only if it is granted an IAM role in the target project.
   - Source: https://firebase.google.com/docs/cloud-messaging/auth-server,
     accessed 2026-10-06.
   - **Consequence for MP-Q2:** a self-hosted daemon cannot push to a
     store-distributed aiur app without either the publisher's credentials
     (unacceptable to ship) or a **publisher-operated push gateway**. That is
     a new service that the `hooks.aiur.dev` tunnel does not provide.
   - Matrix, the substrate Khala uses, has the same shape. Its spec says "A
     client's homeserver forwards information about received events to the
     push gateway. The gateway then submits a push notification to the push
     notification provider (e.g. APNS, GCM)". Source:
     https://spec.matrix.org/latest/push-gateway-api/ (v1.19), accessed
     2026-10-06.
   - That spec does not state *why* the gateway is separate. The credential
     reasoning above is this plan's inference from the Apple and Firebase
     sources, and it is a lead for the N4 planner.
4. **Reusable from R4:** operational patterns only.
   - Outbound-dialled transport with no inbound firewall rule.
   - Path-scoped exposure.
   - A per-request rotatable shared secret.
   - A "polling is the fallback" stance. The phone's equivalent is foreground
     fetch over the private network.

## 5. Contracts

- **Owns:** none.
- **Consumes:**
  - Events and replay (MP-R2). R4 assumes webhook-originated events keep the
    `EventSource` equivalence: the same topic and payload as polling. MP-R2
    must not add a transport-identifying field consumers could branch on.
  - Notification destination and payload (MP-N4). R4 assumes the N4 relay
    port is defined there, with Cloudflare optional and no dependency on
    `hooks.aiur.dev`.

## 6. Non-happy paths (existing behaviour, documented)

| Case | Behaviour |
| --- | --- |
| No tunnel or domain | The repo stays in polling. The "configured but never delivered" state polls at the full interval. |
| Tunnel down after proof | Silence past 900 s means full polling plus an attention. A later delivery restores webhook mode. |
| Secret unset or rotated mid-flight | 401 per delivery plus a throttled alert. GitHub retries are GitHub's own. |
| Duplicate or out-of-order delivery | Handled by the U5 delivery log and version markers (`apis/github.md` § suppression). Unchanged. |
| Tunnel misconfigured host-wide | Every non-webhook route still needs dashboard or supervisor auth (MP-R3 § 1.3). That is defence in depth, **not** a licence to widen the tunnel. |

## 7. Acceptance criteria

1. The docs state that the webhook ingress is vendor-neutral and optional, and
   name what an ingress operator can observe (pending RQ1).
2. The MP-R3-C1 census test lists `:github_webhook` as the only non-dashboard,
   non-supervisor authenticator. Adding a second unauthenticated public route
   fails CI. This is shared with MP-R3; R4 adds no separate test.
3. No change to `src/lib`.
4. § 4 is linked from the MP-N4 plan and from `context-and-decisions.md`
   MP-Q2. The coordinator does the linking.

## 8. Chunks

### MP-R4-C1 — Document the ingress boundary

- **Outcome:** an operator can run webhooks with any ingress, or none, and
  knows what that ingress can see.
- **Dependencies:** MP-R3-C1-T01 (the census asserts the single public route).
  DOCS U8 owner for `apis/github.md` size.
- **Tickets (Phase C, see [tickets/](tickets/README.md)):** MP-R4-C1-T01, one
  PR. It changes `apis/github.md` § Cloudflare tunnel boundary (net +2 lines, the
  heading and anchor kept) and adds one sentence to `optional-optimizations.md`
  § Webhook ingress. The plan's T01/T02 split was merged.
- **Test strategy:**
  - `website/tests/gui-docs.spec.ts:243` asserts `hooks.aiur.dev` is
    mentioned. Keep that mention.
  - No code tests.

### MP-R4-C2 — MP-Q2 fact sheet hand-off (research artifact, not code)

- **Outcome:** § 4 of this plan is the single source the MP-N4 planner cites.
  No implementation ticket.
- **Dependencies:** none.
- **Tickets:** MP-R4-C2-T01 is the coordinator linking step only.

## 9. Open questions

**Owner (Kevin):**

1. Do you want the `hooks.aiur.dev` tunnel kept as-is, purely for GitHub
   webhooks? The plan assumes yes.
2. Would you accept a **publisher-operated** push gateway (a service someone
   runs, possibly you, for the published app) as a dependency of mobile push,
   given that self-hosters cannot hold APNs and FCM credentials? This question
   belongs to MP-N4 and DESIGN-N4. It is raised here because it follows
   directly from § 4.3.

**Research (Phase C):**

- RQ1 (answered in Phase C): yes. Edge certificates "secure the encrypted
  connection between your visitors and Cloudflare"
  (https://developers.cloudflare.com/ssl/edge-certificates/, accessed
  2026-10-06), so TLS ends at the edge and Cloudflare can read delivery bodies.
  The signature stops forgery, not reading.
- RQ2 (answered in Phase C): four `mode_test`s (`:16`, `:25`, `:35`, `:44`) run
  against both `EventSource` implementations, through
  `test/support/webhook_mode_contract.exs`. `:35` is the transport-marker guard
  for MP-R2.

## 10. Plan refresh

- If MP-R1 moves `AiurWeb` or `Aiur.Webhooks` into packages (`ING` #9 is a
  package "only after a `GitHub.Listeners` process split"), update the paths
  in the § 1 table. The docs do not change.
- When MP-N4 lands a push provider port, add a cross-link from
  `apis/github.md` § ingress to the push page, stating that the two are
  separate.
