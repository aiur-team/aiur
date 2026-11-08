# aiur-build-order

Render a published `build-order.v1` graph without aiur.

The package reads one document — the `build-order.v1` contract published by
`@aiur/contracts` — and returns the Build Order review as static HTML, the
dependency graph as SVG, or an `<aiur-build-order>` element that mounts either
or both.

It has no daemon, no network client, no UI framework and no runtime dependency,
and a plain page can load it with no build step.

## Install

```sh
npm install ./aiur-build-order-0.1.0.tgz
npm install aiur-style   # the design tokens the package's stylesheet reads
```

The package is packed and checked in CI; it is not published to a registry yet,
so install the tarball from the release you are consuming.

`aiur-style` is declared as a peer dependency because the package owns no
colour, spacing or type value: every declaration in `aiur-build-order.css`
reads a `var(--aiur-*)` token. The design docs and the ticket call those tokens
`@aiur/style`; the package that publishes them is named `aiur-style`. Load the
tokens once per page (`aiur-style/tokens.css`), then the package stylesheet:

```html
<link rel="stylesheet" href="/node_modules/aiur-style/dist/tokens.css">
<link rel="stylesheet" href="/node_modules/aiur-build-order/aiur-build-order.css">
```

The `aiur-style` peer is optional: without it the markup is complete and
readable but unstyled.

## Exports

| Export | Returns |
| --- | --- |
| `parseBuildOrder(input)` | `{ ok: true, document }` or `{ ok: false, error }` for a JSON string, a parsed object or a fetch body |
| `renderReview(input)` | the review as a static HTML string |
| `renderGraph(input)` | the graph as a static SVG string |
| `registerAiurBuildOrder(registry?)` | defines `<aiur-build-order>` once; `true` when this call defined it |
| `AiurBuildOrderElement` | the element class, for a page that registers it itself |
| `STYLES`, `STYLESHEET_NAME` | the stylesheet text and its file name (`aiur-build-order.css`) |
| `BUILD_ORDER_CONTRACT`, `BUILD_ORDER_VERSION`, `EDGE_TYPES`, `EDGE_LABELS`, `EDGE_NOTES` | the contract marker, the version and the five edge kinds with the words the legend uses |

`renderReview` and `renderGraph` accept a parsed `document`, a JSON string or a
plain object. They throw an error carrying `code` and `path` when the document
does not parse, so an unusable document never renders as a blank box.

The parser keeps the contract's own field names — `waves`, `critical_path`,
`progress`, `edges`, `epics`, `features`, `lanes`, `tickets`, `gates` — and adds
three conveniences: `document.byId` (ticket id → ticket), `document.gatesByKey`
(gate key → gate), and `document.status`, the worst published source status
(`known`, `stale` or `unknown`).

## What the renderers draw from the document

Nothing is recomputed and nothing is guessed:

- **Waves** are the columns of the graph and the sections of the review, from
  `waves`; the order inside a column is the order the document publishes.
- **Lanes** are the rows, ordered by each lane's `order`.
- **The critical path** is `critical_path.tickets`, highlighted in both views,
  with `critical_path.hours` as its headline.
- **Bars and counts** are `progress` (`percent`, `total`, `done`, `open`,
  `failed`) on the document, each epic, feature and lane.
- **Every typed edge** draws its own style and has its own legend entry:
  `depends_on` (solid arrow, with `cleared`, `blocking`, `terminal_unsatisfied`
  or `unknown` as its state), `serializes_with` (dashed), `suggested_after`
  (dotted with a dot head), `contains` (heavy, no head) and `gates` (long dash,
  square head, pointing at a gate node).

### Unknown is visible, never zero

A document whose sources, progress or objects are `status: "unknown"` renders
an explicit banner naming the reason, dashed placeholder bars and `—` where a
number would be. It never draws an empty graph or a `0%` bar, and it still lists
the tickets the document does know about. The same rule applies per epic,
feature and lane.

## The element

```html
<script type="module" src="/node_modules/aiur-build-order/dist/index.js"></script>

<aiur-build-order src="/api/v1/build-order" view="both"></aiur-build-order>
```

Importing the module defines the element when the page has a DOM.

| Attribute or property | Meaning |
| --- | --- |
| `src` | URL fetched with `fetch` (or the element's `fetch` property) and parsed |
| `json` | the document inline, as a JSON string attribute or an object property |
| `view` | `review`, `graph` or `both`; default `both` |
| `.fetch` | a fetch-compatible function used instead of the page's `fetch` |
| `.document` | the parsed document, or `null` |
| `.error` | the structured error, or `null` |
| `.load()` | resolve the current source, parse it and render |

Sources are resolved in order: the `json` attribute or property, then the
`fetch` property for `src`, then the page's `fetch`. A parse or fetch failure
renders the error, sets `data-status="error"` and dispatches
`aiur-build-order:error`; a success dispatches `aiur-build-order:load` with
`detail.document`.

## A complete static page

Save a published document next to this file and open it — no build step, no
bundler and no server:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Build order</title>
<link rel="stylesheet" href="./tokens.css">
<link rel="stylesheet" href="./aiur-build-order.css">
</head>
<body>
<aiur-build-order src="./build-order.v1.json" view="both"></aiur-build-order>
<script type="module">
  import './index.js';
</script>
</body>
</html>
```

`index.js` and `aiur-build-order.css` are the entry files of `dist/` (the other
modules in `dist/` are what `index.js` imports), `tokens.css` is
`aiur-style/tokens.css`, and `build-order.v1.json` is what
`GET /api/v1/build-order` or `aiur build-orders --json --contract
build-order.v1` returns.

To render server-side, or to drop the result into a page yourself, skip the
element:

```js
import { parseBuildOrder, renderReview, renderGraph } from 'aiur-build-order';
import { readFile } from 'node:fs/promises';

const parsed = parseBuildOrder(await readFile('build-order.v1.json', 'utf8'));
if (!parsed.ok) throw new Error(`${parsed.error.code} at ${parsed.error.path.join('.')}: ${parsed.error.message}`);

const html = `${renderReview(parsed.document)}${renderGraph(parsed.document)}`;
```

## The document

The input is the `build-order.v1` contract: `contract: "aiur.build_order"`,
`contract_version: 1`, and the records `sources`, `epics`, `features`, `lanes`,
`tickets`, `edges`, `gates`, `waves`, `critical_path` and `progress`.

The schema, the golden fixtures and the generated TypeScript types live in
`packages/aiur-contracts`. This package's `fixtures/` holds byte-identical
copies of those fixtures, and a unit test fails when they drift.

## Development

```sh
npm run build       # writes dist/ (plain ESM plus the stylesheet; no bundler)
npm run lint        # boundary rules: no network, no console, tokens only, dist current
npm test            # node --test over the parser, both renderers and the element
npm run test:browser # Playwright: the fixture page in Chromium
npm run pack:check  # packs the tarball and renders it in an isolated consumer
```
