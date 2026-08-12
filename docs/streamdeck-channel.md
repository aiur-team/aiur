# Stream Deck channel

Aiur exposes a Phoenix WebSocket at `/streamdeck/websocket` for push-driven
fleet state. Join the single `streamdeck:fleet` channel; internal PubSub topic
names and tuple shapes are not part of this API.

## Authentication

The device first requests `POST /api/v1/streamdeck/token` with the existing
dashboard HTTP Basic credentials. The response is `{token, expires_in_seconds}`.
Pass that token as the Phoenix socket parameter (`/streamdeck/websocket?token=…`),
then join `streamdeck:fleet`.

This adds no device credential: the token can only be minted after dashboard
Basic authentication, expires after five minutes, is signed by the endpoint,
and stops verifying when the dashboard username, password, or signing key
changes. A joined channel closes when that five-minute token window expires or
the dashboard credential configuration changes.
The WebSocket handshake therefore avoids placing a reusable dashboard password
in the upgrade URL while retaining the same authorization boundary. Use
HTTPS/WSS when the dashboard is exposed beyond loopback.

## Events

Every payload is JSON and uses `version: 1` in the initial `snapshot` event.

| Event | Payload | Meaning |
| --- | --- | --- |
| `snapshot` | `{version, fleet, usage, decisions}` | Complete state sent immediately after a successful join. |
| `fleet` | `{agents}` | Complete fleet replacement after a fleet change. |
| `usage` | `{codex, claude}` | Redacted provider-meter projection for the touch-strip usage segments. |
| `decisions` | `{count}` | Updated decision summary. |
| `transcript` | `{identifier, role, body, sequence, timestamp}` | Latest sampled line for the focused agent. |
| `alert` | `{identifier, name, message, severity, needs_attention, timestamp}` | Focused agent alert. |
| `control` | `{identifier, state}` | Focused agent's redacted control state. `state` may contain `action`, `status`, and lifecycle timestamps (`requested_at`, `accepted_at`, `applied_at`, `rejected_at`, `expiry`); request, tracker, and requester details are never exposed. |

An agent item may contain `identifier`, `status`, `alert_count`, `title`,
`runtime_seconds`, `turn_count`, `work_state`, `pause_reason`,
`tracker_paused`, `backend`, and `model`. Fields absent from the source are
omitted rather than represented by implementation-specific sentinels.

## Focus and transcript rate

Send `focus` with `{identifier}` to watch one agent, or `unfocus` to stop. A
channel subscribes to only that one `agent:<identifier>` source; it never fans
out subscriptions for every agent. Re-focusing unsubscribes the prior agent.

Physical key toggles send `control` with `{identifier, action}`, where action
is `pause` or `resume`. The channel routes that request through `Aiur.AgentChat`
and returns the orchestrator result; the device does not implement a second
pause/resume path.

Transcript traffic is latest-value coalesced in 250 ms windows (four pushes per
second maximum per joined channel). A dedicated relay is the sole subscription
to the focused agent, so the channel mailbox is not filled by a transcript
burst. A burst produces one `transcript` event containing the final line from
that window; intermediate lines are intentionally discarded because the device
renders only a small live-log region.
