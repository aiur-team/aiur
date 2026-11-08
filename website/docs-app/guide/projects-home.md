# Projects home

The projects home shows every project on one screen: this gateway, rendered by the server, and each peer gateway, filled in by your browser. It is off by default.

Turn it on in `.aiur/config`:

```yaml
dashboard: { projects_home: true }
```

With the key on, a bare `/` redirects to `/projects`. `/build` and any `/?…` URL with a query string stay on the Build page, so existing links keep working. `/projects` is always served, flag or not. See [`dashboard.projects_home`](/reference/configuration-daemon#dashboard_auth).

## Peers

Peers come from `~/.aiur/remote-instances.yaml` (see [remote instances](/reference/cli-options#remote-instances)). Only entries with a `url` are shown. Add `gateway_id` and `label` to an entry to pin the gateway's identity and name its card.

Your browser fetches `<url>/api/v1/gateway/summary` from each peer with your sign-in cookie, all in parallel, giving up after 3 seconds. So the page paints at once from this gateway, and a slow peer never delays it. A peer must list this page's origin in its `server.dashboard_origins`, or the browser blocks the read and the card reads `unreachable`.

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

## Not here yet

The server summary does not yet carry current agents, queue entries or pending Decisions, so the page says so rather than showing empty lists. Pause-all and cross-gateway queue order are not part of this page.
