# Dashboard stylesheet partials

`AiurWeb.StaticAssets` concatenates every `*.css` here, sorted by file name, into the
single `/dashboard.css` response. The two-digit prefix is the cascade order; keep each
prefix unique so the order never depends on the rest of the name.

Do not create a file above 500 lines. Add rules to the partial that owns the surface,
or start a new partial with an unused prefix at the right point in the cascade.
