# Models API

`GET /api/v1/models` returns configured routes and current dispatch and usage state. It requires the client-token read scope and sends `Cache-Control: no-store`.

The response has `observed_at`, `account_selection`, and `routes`. Routes list `agent.priority` first, then unique `agent.routing` routes by complexity. Each route gives its position, backend, model, effort, configured accounts, source, dispatch status, and usage windows.

Windows include `name`, `used_percent`, `reset_at`, and `freshness`; missing values are `null`, never zero. Provider meters require a signed-in dashboard session, so token-only clients see unknown usage. Dispatch reports missing credentials, capacity holds, and provider limits. Per-ticket model labels and complexity routing can override these global choices.
