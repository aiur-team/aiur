# Build Order Design Manifest

**Imported:** 2026-07-12

**Execution refresh:** 2026-07-13 — re-pulled from the Claude Design project
(source etag `1783996988320902`) and preserved as the distinct versioned file
`prototype/Aiur Operator Control Center.2026-07-13-refresh.html`. It adds a
build-order summary with complexity-weighted phase-progress bars. It does not
replace immutable DESIGN-001 at the canonical path; DEC-015 authorizes BO-020
to consume this versioned execution reference.

The Analytics surface is intentionally excluded from the refresh: the
`assets/analytics.js` loader is removed and the asset is not vendored; the
Analytics navigation item is only an empty placeholder. Analytics is out of
scope and must not be pulled into any ticket.

> The **Confirmed prototype inventory** and **Known prototype/spec drift**
> sections describe DESIGN-001. Apply their drift analysis to the refreshed
> version only where DEC-015 explicitly carries it forward.

**Import commit:** `777cbabbd8baa80482f409f23a71e6ece3787dc9`

**Original project:** `https://claude.ai/design/p/5e62b9a9-39c1-4ca2-9a76-6dff123a088c?file=Aiur+Operator+Control+Center.html`

The prototype is a versioned visual and interaction reference, not executable
product requirements. When it conflicts with explicit user decisions or
the accepted requirements, those decisions win. When the HTML and its companion
constraints disagree, the discrepancy must be resolved rather than silently
choosing whichever is easier to implement.

## Files

| File | SHA-256 |
|---|---|
| `prototype/Aiur Operator Control Center.html` (immutable DESIGN-001) | `504239e1728342651b336f8b39559817a1b6381239e6647b52860a44032f0b38` |
| `prototype/Aiur Operator Control Center.2026-07-13-refresh.html` (DEC-015 execution reference) | `0afe7e5e89de1b5de23bf278f7d02335969533fee81634008339169d87e6190e` |
| `prototype/feature-constraints.md` | `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a` |
| `prototype/README.md` | `f1f6e95194166edc779f0727a7e1a8571c5763a143c27156f105d9e79bea7cd8` |
| `prototype/assets/aiur-logo.png` | `8a6ed8b69be413ba771bb003d7212ee3635a219e6d2abb7d18f64a40ad23fda0` |
| `prototype/assets/claude-symbol.svg` | `be2ee702a76d5ecffa52a7a1c47224e7ad37c13f459cdb25fd9a578dd90287e9` |
| `prototype/assets/claude-token.svg` | `0db46aae46ee078bd471149248c38b38c6309c9c868112303b992e033997d15b` |
| `prototype/assets/codex-color.svg` | `bbae2b981aa4c2c79e8dcf79d56cbdb1ee58a4ebee9b19fb4def152f54da8a34` |
| `prototype/assets/codex-token.svg` | `01b7b779bbf1ca22b92565303517033fadddcd63a6a3af7e4f94e5544414be13` |

## Confirmed prototype inventory

- responsive sidebar navigation for Units, Commands, Build Order, and an
  explicitly future Analytics view; it becomes bottom navigation below 960px;
- a Units-only run summary for Codex/Claude quota, tokens, spend, and an Aiur
  live/ticket/progress/elapsed/ETA summary;
- independent fleet scope presets and state chips, max-agent controls, and a
  per-unit pause/resume affordance;
- four horizontal lanes: Documentation, Frontend, Backend, Infrastructure;
- six rendered phases and 31 sample tickets;
- node cards with logical/ticket ID, complexity, title, status, percentage, and
  progress bar;
- blocker-to-blocked edges, rendered green/solid when cleared and red/dashed
  when blocking;
- hover chain highlighting and a ticket detail modal with GitHub navigation
  plus upstream/downstream dependency links;
- dark and light theme tokens in the inline stylesheet;
- an internally scrollable graph canvas on narrow viewports.

## Known prototype/spec drift

1. The written constraints require pointer pan, wheel/trackpad zoom, `+`/`-`,
   fit-to-view, and 40–160% bounds. The HTML has unused zoom-control CSS but no
   zoom controls or pan/zoom behavior.
2. The docs describe about 20 tickets and phases 1–5; the HTML renders 31
   tickets and phases 1–6. Production must support arbitrary positive phases
   and be tested at 20, 50, and 100 tickets.
3. The docs describe a circled complexity glyph; the visible cards use `Cx:N`.
4. The mock may clear an edge from `100%` Aiur progress. Production may clear a
   dependency only from the authoritative GitHub outcome.
5. Missing edge endpoints disappear silently, graph nodes are mouse-only
   clickable `div`s, and hover has no focus/touch equivalent.
6. The layout and SVG routing are a build-less reliability sketch, not the
   production library/ownership decision.
7. The refreshed mock moves navigation into a responsive sidebar, adds a
   Units-only summary, status filters, pause/resume, and richer ticket context.
   Navigation, Units, controls, and summary work are dedicated members of the
   consolidated Build Order.
   Rich all-state ticket context uses separate root-independent detail
   (BO-016), bounded sanitized history (BO-019), and accessible base-context
   (BO-018) capabilities that Units can adopt, plus a Build Order-only
   relationship adapter (BO-011), rather than one graph-specific component
   being duplicated.
8. At a measured 390 by 844 viewport, the fixed bottom navigation occupies the
   lower safe area and pause controls are about 34px square. Production must
   preserve unobscured content and use at least 44px named touch targets rather
   than copying this density.
9. The written mock treats `icon` as stored ticket metadata. V1 deliberately
   derives deterministic icon keys from the controlled lane and lifecycle,
   with a generic accessible fallback. This avoids another mutable GitHub label
   while preserving the intended visual differentiation; no model call or
   client guess is involved.

The two user-provided screenshots in the planning conversation confirm the
intended dense desktop hierarchy and lower-phase continuation. They are
supplementary references; the committed prototype above is the durable artifact.
The full browser and current-code inventory is recorded in
`06-prototype-capability-audit.md`.
