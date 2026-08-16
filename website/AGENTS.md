# Website Operating Notes

The marketing site (Vite + TypeScript). Deploys to **aiur.team via Netlify
from `main`** — website work pushes directly to `main`, no feature branch.

## `docs-app/` is where the product docs live

`docs-app/` (VitePress) is the documentation every other part of this repo is
required to keep current: `reference/configuration.md` (every config key),
`reference/cli.md` (every command and flag), `guide/` (dashboard, TUI, Stream
Deck, quick start), `concepts/`. The rule that puts docs in the same PR as the
change — and the list of changes exempt from it — is
[`../AGENTS.md#docs-ship-with-the-change`](../AGENTS.md#docs-ship-with-the-change).

**`docs-app/` is the exception to the push-to-`main` note above.** The
direct-to-`main` practice covers the marketing site only. A `docs-app/` edit
that documents a code change belongs in that change's own PR, on that change's
branch — splitting it out is the failure mode this rule exists to stop. A
docs-only correction with no code behind it may still go straight to `main`.

Prefer editing an existing page over adding one; a wrong page is worse than a
missing one. A genuinely new page also needs a sidebar entry in
`docs-app/.vitepress/config.ts` or it is unreachable.

## Guards

Run before every push:

- `npm run typecheck` — `tsc --noEmit`
- `npm run assert` — `tsx scripts/assert-sim.ts`, including a byte-identical
  88-col golden snapshot of the terminal sim. Regenerate the golden only on
  purpose: `npx tsx scripts/gen-golden.ts`.
- `npm run build` — full Vite build.

There is no CI gate for the marketing site, so these guards are the only safety
net. `docs-app/` has one narrow gate: the required `lint` job runs
`scripts/check-config-docs.py`, which fails when a config key has no entry in
`docs-app/reference/configuration.md`. Everything else in `docs-app/` is
unguarded and rests on review.

## Manual browser testing

The terminal sim (`src/dashboard.ts` + `src/styles.css`) is responsive: it
measures `#termScreen` at runtime and lays the opencode pane out by aspect
ratio (taller-than-wide → stacked below; wider-than-tall → split to the
right). Verifying that requires a **real browser at real device sizes**.

**`scripts/shot.ts` is NOT sufficient for layout verification.** It renders a
frame in headless Chromium at a fixed `1100x760` window — great for eyeballing
pane *content*, useless for responsive/mobile behavior. Two failure modes make
a hand-rolled headless harness structurally blind to mobile layout bugs:

1. Plain headless clamps the window to a ~500px minimum width, so it never
   renders true phone widths (375/390px).
2. With mobile emulation that *pins* the layout viewport, horizontal overflow
   can't expand the viewport the way real iOS does — so the very bug you're
   chasing won't reproduce.

This is why a screenshot harness can report "stacked, no overflow" while a real
iPhone shows the pane wrongly side-by-side with clipped text.

### Preferred: agent-browser (compound-engineering)

If `/ce-setup` has been run, the `agent-browser` CLI drives Chrome over CDP
with proper device emulation that reaches sub-500px widths:

```sh
agent-browser open http://localhost:5173      # or https://aiur.team
agent-browser set device "iPhone 12"
agent-browser set viewport 390 844 3          # w h devicePixelRatio
agent-browser set media dark reduced-motion
agent-browser eval "<js>"                      # measure layout (see below)
agent-browser screenshot /tmp/check.png
```

Verify across at least 360x780, 375x667, 390x844 (all should stack) and
844x390 (should split right). A useful `eval` payload reports `innerWidth`,
`document.documentElement.scrollWidth`, `#termScreen` `{w,h}`, the rendered
`cols`/`rows`, whether the pane is stacked vs side-by-side, and any element
whose right edge exceeds the viewport (the overflow offender).

### Fallback: no compound-engineering

`agent-browser` ships with compound-engineering; not every agent has it. Without
it, drive Chrome/Chromium directly over CDP and **emulate the device** — do not
just set `--window-size`. Use `Emulation.setDeviceMetricsOverride` with
`mobile: true` and a real DPR (e.g. width 390, height 844, deviceScaleFactor 3),
then `Runtime.evaluate` the same measurement JS above. The real-WebKit provider
(`agent-browser -p ios`) needs Xcode and is unavailable on Linux; Chrome device
emulation is the closest substitute and reproduces these layout bugs reliably.
