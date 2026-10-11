import { TICKETS, LOOP_SECONDS, BEAT } from "./simData";
import {
  DASH_BOX_W_ABBR, OC_GUTTER, OC_PANE_W, MIN_COLS, VISIBLE_TICKETS, FIXED_ROWS,
  MIN_LOG_LINES, WIDE_LOG_LINES, OC_MIN_ROWS, layout,
} from "./sim/geometry";
import { SPIN, dashes } from "./sim/segments";
import { buildDashboardLines } from "./sim/dashboardBox";
import { buildOpencodeLines } from "./sim/opencodePane";

// Public surface stays importable from "./dashboard".
export { DASH_BOX_W, DASH_BOX_W_ABBR } from "./sim/geometry";
export { OC_PANE_W } from "./sim/geometry";
export { buildDashboardLines } from "./sim/dashboardBox";
export { buildOpencodeLines } from "./sim/opencodePane";

// Wide-terminal flag. Only sets the log-line floor (a minimum; fitLogLines
// computes the real count from height). Set by chooseLayout.
let wide = true;

// The ticket the Executor "takes the wheel" on during the beat (R3).
const DRIVEN_ID = 321;

// Selection-cursor row index (0..VISIBLE_TICKETS-1) as a pure function of
// loopSec: descends row 0 → #321 before the pane opens, pins on #321 while
// open, ascends back to the top after it closes (R-V5). One row per STEP.
const STEP = 0.5;
function selectedRow(loopSec: number): number {
  const last = VISIBLE_TICKETS - 1;
  if (loopSec >= BEAT.descentStart && loopSec < BEAT.open) {
    return Math.min(last, Math.floor((loopSec - BEAT.descentStart) / STEP));
  }
  if (loopSec >= BEAT.open && loopSec < BEAT.close) return last;
  if (loopSec >= BEAT.close && loopSec < BEAT.ascentEnd) {
    return Math.max(0, last - Math.floor((loopSec - BEAT.close) / STEP));
  }
  return 0;
}

// Layout flag for the beat split: side-by-side when the viewport is wide
// enough, stacked otherwise. Resize-driven module state (not loop-driven) so
// renderFrame is a pure read — see chooseLayout for the hysteresis band.
let sideBySide = true;

// Stitch the abbreviated dashboard (left) beside the opencode pane (right).
// Left rows are already DASH_BOX_W_ABBR wide and right rows OC_PANE_W, so each
// joined row is exactly WIDTH cols. The shorter column is padded with blank,
// full-width rows so borders stay aligned and the height matches the dashboard.
export function joinColumns(
  left: string[],
  right: string[],
  paneW: number = OC_PANE_W,
): string[] {
  const blankL = " ".repeat(DASH_BOX_W_ABBR);
  const blankR = " ".repeat(paneW);
  const gutter = " ".repeat(OC_GUTTER);
  const rows = Math.max(left.length, right.length);
  const out: string[] = [];
  for (let i = 0; i < rows; i++) {
    out.push((left[i] ?? blankL) + gutter + (right[i] ?? blankR));
  }
  return out;
}

function stackRule(): string {
  return dashes(layout.cols, "bd").h;
}

export function renderFrame(nowMs: number, baseMs: number): string {
  const loopSec = ((nowMs - baseMs) / 1000) % LOOP_SECONDS;
  const spinIdx = Math.floor(nowMs / 100) % SPIN.length;
  const paneOpen = loopSec >= BEAT.open && loopSec < BEAT.close;
  const sel = selectedRow(loopSec);

  let body: string[];
  if (!paneOpen) {
    // Full-width dashboard. The selection cursor walks the agent list during
    // descent/ascent ([descentStart, open) and [close, ascentEnd)); row 0 otherwise.
    body = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: false,
      selectedId: TICKETS[sel].id,
    });
  } else if (sideBySide) {
    // Abbreviated dashboard stays a fixed 30 cols; the pane absorbs the rest of
    // the grid width. Both columns are the same height (the dashboard's), so the
    // combined split fills the terminal exactly — no overflow, no padded floor.
    const paneW = Math.max(MIN_COLS, layout.cols - DASH_BOX_W_ABBR - OC_GUTTER);
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: true,
      selectedId: DRIVEN_ID,
    });
    const pane = buildOpencodeLines(loopSec, spinIdx, dash.length, paneW);
    body = joinColumns(dash, pane, paneW);
  } else {
    // Stacked (portrait): a compact dashboard (one log line) on top, then the
    // pane fills the remaining height. The pane is sized to the height slack so
    // the stack totals the terminal's row count exactly — no bottom clipping.
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: false,
      selectedId: DRIVEN_ID,
      logOverride: 1,
    });
    const gridRows = FIXED_ROWS + layout.logLines;
    const paneRows = Math.max(OC_MIN_ROWS, gridRows - dash.length - 1);
    const pane = buildOpencodeLines(loopSec, spinIdx, paneRows, layout.cols);
    body = [...dash, stackRule(), ...pane];
  }

  return `<pre class="tui-pre">${body.join("\n")}</pre>`;
}

export function startDashboard(screen: HTMLElement): void {
  const baseMs = performance.now();
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Reduced-motion freezes one frame in [replyAt, close): pane open with the
  // posted "lets brainstorm options" block and the agent's reply both visible,
  // the input field empty, and the cursor static (CSS suppresses its blink).
  const nowMs = (): number => (reduce ? baseMs + 22_000 : performance.now());

  // Pick the beat split from the terminal's own aspect ratio: a wider-than-tall
  // box puts the dashboard and pane side by side; a taller-than-wide (portrait)
  // box stacks the pane below. Using the element's own width:height ratio rather
  // than viewport width / orientation media queries is DPR-proof — high-density
  // iOS screens were reporting "wide" and forcing the side-by-side desktop split
  // onto portrait phones, clipping the pane off the right edge.
  const chooseLayout = (): void => {
    const r = screen.getBoundingClientRect();
    sideBySide = r.width > r.height;
    wide = r.width >= 700;
  };

  const tick = (): void => {
    screen.innerHTML = renderFrame(nowMs(), baseMs);
  };

  // Set the full-width column count so the grid fills the container exactly at
  // the current (clamped) font size. The font is container-query driven, so the
  // per-character pixel width is independent of how many columns we render —
  // measuring the live pre (rendered at the current `cols`) yields charW, and
  // floor(containerWidth / charW) is the count that fits with no overflow and no
  // empty gutter. This contracts the grid on phones (fewer cols, no right-edge
  // clipping) and expands it on wide screens (more cols feed TITLE/LATEST).
  const fitWidth = (): void => {
    const pre = screen.querySelector(".tui-pre") as HTMLElement | null;
    if (!pre) return;
    const charW = pre.getBoundingClientRect().width / layout.cols;
    const avail = screen.clientWidth;
    if (charW > 0 && avail > 0) {
      layout.cols = Math.max(MIN_COLS, Math.floor(avail / charW));
    }
  };

  // The log section grows to fill whatever vertical slack the fixed grid leaves,
  // so the box always reaches the terminal floor. The floor differs by width:
  // wide screens cap the font (tall rows) and can be short, so they stay compact
  // (WIDE_LOG_LINES) when there's no slack; narrow screens shrink the font to fit
  // width and leave more slack to fill (MIN_LOG_LINES). Line height tracks width
  // (font-size) only, so it's stable across row counts and the estimate is exact.
  const fitLogLines = (): void => {
    const pre = screen.querySelector(".tui-pre") as HTMLElement | null;
    if (!pre) return;
    const floorLines = wide ? WIDE_LOG_LINES : MIN_LOG_LINES;
    // Per-row height from the actual rendered row count, not the assumed
    // pane-closed count: the measured frame can be a beat frame (reduced motion
    // freezes mid-beat) with a different number of rows.
    const renderedRows = (pre.textContent ?? "").split("\n").length;
    const lineH = pre.getBoundingClientRect().height / renderedRows;
    const avail = screen.clientHeight;
    if (lineH > 0 && avail > 0) {
      layout.logLines = Math.max(floorLines, Math.floor(avail / lineH) - FIXED_ROWS);
    }
  };

  // One layout pass: render once so the pre is measurable, derive the column
  // count and log-line count from that render, then render again at the final
  // geometry. charW (fitWidth) and lineH (fitLogLines) are both width/font
  // driven and independent of the row/column counts, so one re-render suffices.
  const relayout = (): void => {
    chooseLayout();
    tick();
    fitWidth();
    fitLogLines();
    tick();
  };

  relayout();

  // Re-decide on any change to the terminal's own box — viewport resize, device
  // rotation, and the mobile URL bar showing/hiding all resize #termScreen, and
  // the side-by-side-vs-stacked choice keys off its width:height ratio. Observing
  // the element directly (not window 'resize', which can miss late mobile layout
  // shifts) keeps the layout honest to the box the user actually sees.
  let rzTimer = 0;
  const ro = new ResizeObserver(() => {
    clearTimeout(rzTimer);
    rzTimer = window.setTimeout(relayout, 150);
  });
  ro.observe(screen);
  void document.fonts?.ready.then(relayout);

  if (!reduce) window.setInterval(tick, 100);
}

