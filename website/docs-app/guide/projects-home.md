# Projects home

The projects home shows every project on one screen: this gateway, rendered by the server, and each peer gateway, filled in by your browser. It is off by default.

Turn it on in `.aiur/config`:

```yaml
dashboard: { projects_home: true }
```

With the key on, a bare `/` redirects to `/projects`. `/build` and any `/?…` URL with a query string stay on the Build page, so existing links keep working. `/projects` is always served, flag or not. See [`dashboard.projects_home`](/reference/configuration-daemon#dashboard_auth).

## Peers

Peers come from `~/.aiur/remote-instances.yaml` (see [remote instances](/reference/cli-options#remote-instances)). Only entries with a `url` are shown. Add `gateway_id` and `label` to an entry to pin the gateway's identity and name its card.

Your browser fetches `<url>/api/v1/gateway/summary` from each peer with your sign-in cookie, all in parallel, giving up after 3 seconds. So the page paints at once from this gateway, and a slow peer never delays it.

A peer must list this page's origin in its `server.dashboard_origins`, or the browser blocks the read and its card reads `unreachable`; every card shows one of these:

| Card says | Meaning |
|---|---|
| `online` | The peer answered and the answer matched its pinned `gateway_id`. |
| `unreachable · last seen 5m ago` | No answer within 3 s, or the browser blocked it. The card shows the last summary this browser saw, with its age. |
| `unknown · never seen on this device` | No answer and nothing cached. |
| `error: signed out` | The peer answered 401 or 403. A `Sign in` link opens that peer's sign-in. |
| `error: gateway id mismatch` | The peer answered as a different gateway. Its numbers are discarded. |
| `error: unreadable summary` / `error: server N` | The answer was malformed or a 5xx. |

An unreachable peer is never shown as `0 agents` or idle, and its cached numbers are not added to the total. The header reads `Running 7 of 12+ · 1 gateway unknown` when any gateway is missing from the sum. Cached summaries live in this browser's `localStorage` for 7 days. A peer whose URL is not `https` is not fetched; open it from its card.

Each gateway card links to its own dashboard, and the local card links to [Build](/guide/dashboard-and-telemetry).

## Gateways and pause

`/gateways` shows one card per gateway; `/gateways?gateway=nook` shows one (a registry name, or `local`). The Projects page links each peer there.

Each card has `connectivity` (`online`, `unreachable`, `offline`, `unknown`, `error`) and `workload` (`idle`, `active`, `saturated`) as **two separate fields**. An online gateway can be idle.

A gateway that does not answer has no workload, only the last one this browser saw, marked `last known`. `offline` means the shared roster has had no heartbeat from it for `coordination.offline_after_seconds`.

`Pause <gateway>` pauses that gateway. `Pause all` asks for confirmation, writes the shared `fleet.pause` intent through this gateway, then pauses every gateway it can reach directly, and lists one line each:

| Line | Meaning |
|---|---|
| `paused ✓` | The gateway answered and is paused. |
| `will pause on reconnect` | It did not answer, but the pause is in the shared intent and applies when it syncs. |
| `not paused: unreachable and no shared store` | It did not answer and the intent could not be stored. |
| `not paused: signed out` | It answered 401 or 403. |
| `not paused: off tailnet, pause it from its own dashboard ↗` | Its URL is not `https`, so the browser does not call it. |

The buttons call `POST /api/v1/gateway/pause` and `/resume` (this gateway) and `POST /api/v1/fleet/pause` and `/resume` (shared intent plus this gateway).

They need a dashboard session or a `write` client token, the `X-Aiur-Request: 1` header, and a same-origin or `server.dashboard_origins` `Origin`. `observability.dashboard_writable: false` blocks them.

Each call sets an absolute state, so a retry is harmless, and `request_id` is echoed. The fleet response carries `intent_written`.

## Not here yet

The server summary does not yet carry current agents, queue entries or pending Decisions, so both pages say so rather than showing empty lists. There is no per-project pause or resume-all button yet (the endpoints exist), and no cross-gateway queue order.
