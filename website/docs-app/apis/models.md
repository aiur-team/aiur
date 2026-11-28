# Models API

`GET /api/v1/models` returns the configured agent routes and their current dispatch and usage state. It requires the dashboard client-token read scope and sends `Cache-Control: no-store`.

The response contains `observed_at`, `account_selection`, and `routes`. Routes are ordered as the dispatcher considers them: `agent.priority` first, followed by additional `agent.routing` routes by complexity. Duplicate route strings appear once. Each route includes its one-based `position`, `backend`, `model`, `effort`, configured `accounts`, source, dispatch availability and reason, plus usage windows. Provider meter values are included only for a signed-in dashboard session; token-only clients receive unknown usage rather than bypassing the dashboard's financial-data boundary.

Each usage window has `name`, `used_percent`, `reset_at`, and `freshness`. `used_percent` and `reset_at` are `null` when no observation supplies them; clients must preserve unknown as unknown rather than display zero. Dispatch reports missing credentials and a currently held provider limit. Per-ticket `model:<backend>` labels and complexity routing can override the global preference, so this endpoint describes configured choices rather than predicting an individual ticket.
