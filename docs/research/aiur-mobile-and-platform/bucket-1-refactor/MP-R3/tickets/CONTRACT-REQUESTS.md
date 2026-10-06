# MP-R3 requests to the coordinator

## CR-R3-1 — add the § Transport copy to DESIGN-R3 §3 (owner-design-tasks, coordinator-owned)

RC-15 gives MP-R3 "docs and bind guards" for RQ-TRANSPORT. MP-R3-C2-T01 adds a
§ Transport paragraph to `website/docs-app/reference/optional-optimizations.md`.
DESIGN-R3 §3 currently asks the owner to approve only the § Tailscale copy.
Please add this copy for approval, under the same "approved / edits" checkbox:

> Aiur serves the dashboard over plain HTTP and never terminates TLS. Off the
> machine, encryption is the network's job — a tailnet encrypts the path; a LAN
> does not. Browsers allow the microphone only on HTTPS or `localhost`, so
> dashboard dictation is disabled on a plain-HTTP address beyond loopback.

Evidence:

- `http_server.ex:64,147`;
- `conversation-voice-controller.js:18-19`;
- MDN `getUserMedia` secure-context note (accessed 2026-10-06).

The copy names no HTTPS method, so it does not pre-empt DESIGN-N2 §transport.

## CR-R3-2 — update the DESIGN-R3 `blocks:` line

DESIGN-R3 front matter lists `MP-R3-C1-T01..T02, MP-R3-C2-T01..T02`. Phase C has
two tickets: `MP-R3-C1-T01` and `MP-R3-C2-T01`.
