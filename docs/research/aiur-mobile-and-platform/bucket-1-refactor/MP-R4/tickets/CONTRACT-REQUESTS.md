# MP-R4 requests to the coordinator

## CR-R4-1 — resolve the bracket in the DESIGN-R4 §3 copy

DESIGN-R4 §3 says "Whoever operates the ingress can see each delivery's
metadata [and body — pending Phase C confirmation]". Phase C answered it: **body
too**. Cloudflare edge certificates "secure the encrypted connection between
your visitors and Cloudflare"
(https://developers.cloudflare.com/ssl/edge-certificates/, accessed
2026-10-06), so TLS terminates at the edge. Please replace the bracket with
"and body; the webhook signature prevents forgery, not reading" before the owner
approves.

## CR-R4-2 — update the DESIGN-R4 `blocks:` line

It lists `MP-R4-C1-T01..T02`. Phase C has one ticket, `MP-R4-C1-T01`.

## CR-R4-3 — input for MP-R2 (no contract change requested)

`src/test/aiur/webhooks/consumer_equivalence_test.exs:35`, "the consumer is
handed no transport marker to branch on", runs against both
`EventSource.Polling` and `EventSource.Webhook`. The MP-R2 bus move should keep
it running unchanged. This matches the events-and-replay assumption in MP-R4
plan § 5.
