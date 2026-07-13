# Build Order Design Manifest

**Imported:** 2026-07-12

**Import commit:** `fc3162f2f56e3b53d825871ce60efcffee9d2a44`

**Original project:** `https://claude.ai/design/p/5e62b9a9-39c1-4ca2-9a76-6dff123a088c?file=Aiur+Operator+Control+Center.html`

The prototype is a versioned visual and interaction reference, not executable
product requirements. When it conflicts with explicit operator decisions or
the accepted requirements, those decisions win. When the HTML and its companion
constraints disagree, the discrepancy must be resolved rather than silently
choosing whichever is easier to implement.

## Files

| File | SHA-256 |
|---|---|
| `prototype/Aiur Operator Control Center.html` | `a5c2a1bfd780a4f7b4656f4ba3765780c4e127dc4ace3d1fe31e0d04b468fe90` |
| `prototype/feature-constraints.md` | `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a` |
| `prototype/README.md` | `f1f6e95194166edc779f0727a7e1a8571c5763a143c27156f105d9e79bea7cd8` |
| `prototype/assets/aiur-logo.png` | `8a6ed8b69be413ba771bb003d7212ee3635a219e6d2abb7d18f64a40ad23fda0` |
| `prototype/assets/claude-symbol.svg` | `be2ee702a76d5ecffa52a7a1c47224e7ad37c13f459cdb25fd9a578dd90287e9` |
| `prototype/assets/claude-token.svg` | `0db46aae46ee078bd471149248c38b38c6309c9c868112303b992e033997d15b` |
| `prototype/assets/codex-color.svg` | `bbae2b981aa4c2c79e8dcf79d56cbdb1ee58a4ebee9b19fb4def152f54da8a34` |
| `prototype/assets/codex-token.svg` | `01b7b779bbf1ca22b92565303517033fadddcd63a6a3af7e4f94e5544414be13` |

## Confirmed prototype inventory

- three primary views: Units, Commands, Build Order;
- four horizontal lanes: Documentation, Frontend, Backend, Infrastructure;
- six rendered phases and 31 sample tickets;
- node cards with logical/ticket ID, complexity, title, status, percentage, and
  progress bar;
- blocker-to-blocked edges, rendered green/solid when cleared and red/dashed
  when blocking;
- hover chain highlighting and a ticket detail modal;
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

The two operator-provided screenshots in the planning conversation confirm the
intended dense desktop hierarchy and lower-phase continuation. They are
supplementary references; the committed prototype above is the durable artifact.
