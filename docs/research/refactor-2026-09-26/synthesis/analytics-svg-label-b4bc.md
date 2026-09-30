# Analytics SVG label path at `main@b4bc11f`

Two independent read-only reviews challenged the surviving `web-occ-12`
finding on detached `b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`.
The strongest source path is a provider model string:

1. OpenAI-compatible usage extraction accepts `payload["model"]` as the
   resolved model (`src/lib/aiur/usage/headless/open_ai_compat/request_usage.ex:53-61`).
   Usage-envelope opaque validation permits trimmed UTF-8 strings up to 256
   bytes, including angle brackets (`src/lib/aiur/usage_envelope.ex:391-395`).
2. The grouped `by_model` key reaches `UsageSummaryPresenter.present_model/1`,
   whose binary label branch returns it unchanged
   (`src/lib/aiur_web/operator_control_center/usage_summary_presenter.ex:263-280,308-311`).
3. `Analytics.Charts.model_tokens_timeline/1` interpolates the full label into
   an SVG `<title>` and a shortened, still unescaped label into `<text>`
   (`src/lib/aiur_web/operator_control_center/analytics/charts.ex:419-420,481-485,611-615`).
   `UsageSummary` inserts that SVG with `Phoenix.HTML.raw` on the dashboard
   (`src/lib/aiur_web/components/operator_control_center/usage_summary.ex:92-94`).

Actor labels and ticket IDs have analogous raw `<text>` paths in
`Charts.cost/3` and `Charts.gantt/1`; actual tracker ticket-ID validation may
limit the latter. The routes require dashboard authentication. No explicit
application CSP was found in the router/endpoint path, but neither reviewer
ran a browser or demonstrated script execution. The supported conclusion is
stored SVG/HTML injection potential, with browser effect still to prove.

Focused test: feed a model label such as
`</title></line><text x="40" y="40" id="aiur-marker">MARKER</text><line><title>`
through the usage presenter and rendered component. Assert the SVG has no
`#aiur-marker` element and that the full title and shortened display label
are escaped text. Include actor and ticket labels in the shared chart
builder test. The test must fail with the production escaping change reverted
and pass after restoration, following AGENTS.md. Keep the fix at the SVG
encoding boundary; do not alter the stored provider model identity.
