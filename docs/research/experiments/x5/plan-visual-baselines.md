---
title: "test: Experiments page visual baselines and responsive matrix (EXP-X5-4) - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
date: 2026-10-09
epic: aiur-team/aiur#3774
origin: docs/research/experiments/x5/brainstorm.md
---

# test: Experiments page visual baselines and responsive matrix (EXP-X5-4) - Plan

## Goal Capsule

- **Objective.** Lock the finished page's look with pixel baselines in both themes at desktop and mobile widths, for the normal, empty and not-enough-data states, plus a responsive reflow matrix. Produce the side-by-side screenshot sheet Kevin signs off (brainstorm Q1).
- **Product authority.** `docs/research/experiments/x5/brainstorm.md` R6, R8, D6, D7, D9. Product Contract unchanged.
- **Open blockers.** EXP-X5-1, EXP-X5-2 and EXP-X5-3 merged (baselines of a half-built page churn).

---

## Summary

Add `src/browser/tests/experiments-visual.browser.spec.mjs` and `experiments-responsive.browser.spec.mjs`, following `visual-shell.browser.spec.mjs` (themes x viewports, pinned Chromium, `openVisualRoute`, `reducedMotion: 'reduce'`, `deviceScaleFactor: 3` on mobile) and `build-order-responsive.browser.spec.mjs` (320/390/768/960/1280 reflow with `assertNoDocumentOverflow`). Data comes from the deterministic fixture scenarios added in EXP-X5-1 U5.

## Key Technical Decisions

- **KTD1 Matrix.** Themes `light`, `dark`; viewports 1440x900, 1024x768 (desktop, nav expanded) and 390x844 (mobile). Palette `gruvbox` only for pages; one `aiur` palette cell at 1440 dark to catch token mistakes. Reason: the same matrix as the shell baselines, without multiplying cells by every palette.
- **KTD2 States per cell.**

  | State | Route | Scenario | Screenshot targets |
  |---|---|---|---|
  | normal line experiment | `/experiments/<line-id>` | `mixed` | full page, `.exp-index`, `#exp-charts`, `#exp-report` |
  | cohort experiment | `/experiments/<cohort-id>` | `cohorts` | `#exp-charts` |
  | not enough data | `/experiments/<thin-id>` | `not-enough-data` | full page |
  | empty | `/experiments` | `empty` | full page |
  | index only (mobile) | `/experiments` | `mixed` | full page, 390 only |
  | report pending | `/experiments/<no-report-id>` | `mixed` | `#exp-report` |
  | custom metric pack | `/experiments/<pack-id>` | `custom-pack` | `.exp-summary` |

- **KTD3 Masks.** Only live values: relative times (`.exp-age`), and nothing else. Chart geometry and numbers are fixture-fixed and stay visible. Add the selector to `VISUAL_MASKS` in `src/browser/support/visual.mjs` with its reason.
- **KTD4 Fixed time.** The fixture sets the page clock (the same clock override the shell fixture uses for ages) so "3 days ago" never drifts; if no override exists, relative times are masked (KTD3).
- **KTD5 Responsive matrix (no pixels).** At 320, 390, 768, 960 and 1280: no document overflow; every index link, back link, metric selector and "Show data" control keeps a 44 px target on touch; the summary switches from table to cards below the breakpoint; the time series container (not the page) scrolls; no fact is dropped (row counts equal at every width). 200% text zoom at 390 keeps the same facts.
- **KTD6 Sign-off sheet.** A spec step writes a contact sheet (desktop and mobile, light and dark, normal and not-enough-data) to the test artifacts so the Executor can post it on the ticket for Kevin. The baselines are committed only after his sign-off on Q1; until then the PR carries them and stays in human review.

## Implementation Units

### U1. Visual baseline spec

**Goal:** Pixel baselines for the matrix in KTD1-KTD3.
**Requirements:** R8, R6.
**Dependencies:** EXP-X5-1..3.
**Files:** `src/browser/tests/experiments-visual.browser.spec.mjs`, `src/browser/tests/experiments-visual.browser.spec.mjs-snapshots/*`, `src/browser/support/visual.mjs`.
**Test scenarios:** one screenshot test per (theme, viewport, state) cell in KTD2; each asserts the LiveView is connected and the expected `data-empty-reason` (or none) before the screenshot.
**Verification:** suite green twice in a row on the pinned Chromium (no flake).

### U2. Responsive and accessibility spec

**Goal:** Behavioural checks across widths.
**Requirements:** R6, D6, D10.
**Dependencies:** EXP-X5-1..3.
**Files:** `src/browser/tests/experiments-responsive.browser.spec.mjs`.
**Test scenarios:**
- KTD5 checks at each width.
- Covers AE5 at 390.
- `prefers-reduced-motion: reduce`: selecting an experiment causes no CSS transition longer than 0 ms.
- Axe on normal, empty and not-enough-data states in both themes: no serious or critical violations.
- Colour-independence: with a grayscale filter applied, the expected-direction label, guard chips and cohort markers still differ by text or shape (assert the text nodes and `data-shape` attributes, not pixels).
**Verification:** suite green.

### U3. Contact sheet for sign-off

**Goal:** Give Kevin one image to approve.
**Requirements:** Q1.
**Dependencies:** U1.
**Files:** `src/browser/tests/experiments-visual.browser.spec.mjs` (an artifact-only test tagged so CI keeps it as an attachment).
**Test expectation:** none -- produces an artifact, asserts only that it was written.
**Verification:** the artifact appears in the CI run and is linked on the ticket.

---

## Scope Boundaries

- No design-parity matrix cell for this page: the Claude Design has no Experiments page to compare with. If Kevin commissions one (Q1), a parity cell is a follow-up.
- Shell nav baselines are regenerated in EXP-X5-1 U6, not here.

## Risks

- **Font or chart rendering drift between machines.** Mitigated by the pinned Chromium container already used by `visual.mjs`.
- **Fixture time.** KTD4.

## Definition of Done

U1-U3 merged after Kevin's sign-off; browser suites green on the head SHA.
