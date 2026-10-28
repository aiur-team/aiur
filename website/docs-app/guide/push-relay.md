# Push relay

The standalone relay in `packages/aiur-push-relay` accepts opaque sealed notifications
and sends APNs alerts over HTTP/2. Deploy it separately from the daemon. Public
deployment still requires the abuse controls and TLS setup from the deployment work.

## Apple credentials

Set these in the relay process environment, then restart the relay:

| Variable | Value | Default |
| --- | --- | --- |
| `AIUR_RELAY_APNS_TEAM_ID` | Apple developer team ID | None |
| `AIUR_RELAY_APNS_KEY_ID` | APNs signing key ID | None |
| `AIUR_RELAY_APNS_KEY_FILE` | Path to the P-256 `.p8` private key, file mode `0600` | None |

Missing, unreadable, invalid or incorrectly permissioned credentials disable APNs.
`GET /healthz` then reports `"apns":"unavailable"`; APNs handle registration returns
`503 provider_unavailable`. Store health still determines the health endpoint's HTTP
status. FCM registration remains unavailable until its adapter is configured.

Configure `AIUR_RELAY_APP_TOPICS` and a JSON fallback pin in
`AIUR_RELAY_FALLBACK_<APP_TOPIC_SLUG>` for each topic. The relay uses that pin for
every visible alert and never uses caller-supplied alert text. Full startup and HTTP
examples are in the package README.

The handle environment selects Apple's sandbox or production host. Provider JWTs
refresh every 40 minutes; an expired-token response triggers one refresh and retry.
Unregistered or invalid device tokens mark the handle gone, making later sends return
`410`. Throttling records a 60-second retry hint; transport and server failures record
a 5-second hint. Retry scheduling is not yet supplied by this package.

Apple sandbox acceptance with real credentials is a separate deployment check.
Keep signing keys outside Git and do not expose tokens or sealed content in logs.
