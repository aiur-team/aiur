// ---- frame geometry (character columns) ----
export const MARKER = 2;
export const IDW = 4;
export const AGENTW = 7;
export const STATUSW = 3;
export const TITLEW = 24;
export const LATESTW = 28;
export const PROGW = 11;
export const TIMEW = 5;
export const INNER = MARKER + IDW + AGENTW + STATUSW + TITLEW + LATESTW + PROGW + TIMEW; // 84
export const WIDTH = INNER + 4; // 88 incl. "│ " and " │"

// Two dashboard geometries. fullGeom(cols) is the responsive full-width grid:
// the marker, ID, AGENT, STATUS, PROGRESS and TIME columns are fixed; TITLE and
// LATEST flex to consume whatever inline width the terminal gives us, so the
// box always fills the container exactly — no empty gutter on wide screens, no
// right-edge clipping on phones. ABBR is the ~1/3-width pane shown beside the
// opencode pane during the take-the-wheel beat: AGENT, LATEST and TIME columns
// drop, TITLE truncates, and PROGRESS becomes a percentage.
export interface Geom {
  id: number;
  agent: number; // 0 = dropped
  status: number;
  title: number;
  latest: number; // 0 = dropped
  prog: number;
  time: number; // 0 = dropped
  inner: number;
  width: number;
  dropLatest: boolean;
}
// TITLE never needs to exceed the longest visible title (~25 cols); past that,
// extra width is better spent on LATEST, which carries the longest strings.
export const TITLE_CAP = 26;
export const TITLE_MIN = 10;
export const LATEST_MIN = 12;
// Smallest grid we'll render. Below this the font floor would force overflow no
// matter what; the clamp keeps the box from collapsing on absurdly narrow boxes.
export const MIN_COLS = 44;
// At WIDTH (88) this returns exactly today's full-width grid (title 24 / latest
// 28) so the golden snapshot stays byte-identical; wider/narrower cols reflow
// the two flex columns while keeping their sum equal to the inner width.
export function fullGeom(c: number): Geom {
  const width = Math.max(MIN_COLS, c);
  const inner = width - 4; // "│ " + " │"
  const fixedFull = MARKER + IDW + AGENTW + STATUSW + PROGW + TIMEW; // 32
  // Drop the AGENT column when there isn't room for it alongside the TITLE and
  // LATEST minimums (R: "hide the agent column if there's not enough room").
  const agent = inner - fixedFull >= TITLE_MIN + LATEST_MIN ? AGENTW : 0;
  const fixed = fixedFull - (AGENTW - agent);
  // No hard flex floor: the flex columns get exactly the inner width that's left
  // so the ticket rows can never be wider than the border. When that's below the
  // TITLE/LATEST minimums the cells simply truncate with an ellipsis — text is
  // shortened, never clipped, and the box always closes at the terminal width.
  const flex = Math.max(0, inner - fixed);
  let title = Math.max(TITLE_MIN, Math.min(TITLE_CAP, Math.round(flex * 0.46)));
  let latest = flex - title;
  if (latest < LATEST_MIN) {
    latest = Math.min(flex, LATEST_MIN);
    title = flex - latest;
  }
  return {
    id: IDW, agent, status: STATUSW, title,
    latest, prog: PROGW, time: TIMEW,
    inner, width, dropLatest: false,
  };
}
// Dashboard full-width column count. Default 88 keeps Node-side renders (golden,
// assert) on the historical grid; the browser raises/lowers it in fitWidth.
// Mutable layout state shared across sim modules (set by startDashboard).
// cols: full-width column count. Default 88 keeps Node-side renders (golden,
// assert) on the historical grid; the browser raises/lowers it in fitWidth.
export const layout = { cols: WIDTH, logLines: 0 };
export const TITLE_S = 11;
export const PROG_S = 6;
export const INNER_S = MARKER + IDW + STATUSW + TITLE_S + PROG_S; // 26
export const ABBR: Geom = {
  id: IDW, agent: 0, status: STATUSW, title: TITLE_S,
  latest: 0, prog: PROG_S, time: 0,
  inner: INNER_S, width: INNER_S + 4, dropLatest: true,
};
export const DASH_BOX_W = WIDTH;
export const DASH_BOX_W_ABBR = INNER_S + 4;

// opencode pane geometry. The pane sits to the right of the abbreviated
// dashboard during the beat. Width is derived so the combined split
// (dashboard + gutter + pane) equals WIDTH, keeping the container-query font
// ratio unchanged (no overflow/clip). No rail: every pane row fills OC_PANE_W.
export const OC_GUTTER = 1; // blank cols between dashboard box and pane
export const OC_PANE_W = WIDTH - DASH_BOX_W_ABBR - OC_GUTTER; // 57
// Show the top slice of the fleet so the grid fills width without the rows
// overflowing the terminal's height at large font sizes.
export const VISIBLE_TICKETS = 6;
// Rows that aren't tickets or log lines: top border, 3 header rows, 2 dividers,
// column header, log divider, bottom border.
export const NON_TICKET_ROWS = 9;
// Event-log rows. On narrow screens this grows at runtime to fill the
// terminal's vertical slack (see startDashboard); on wide screens it's pinned
// low so the grid stays compact and vertically centered. Every non-log row is
// fixed, so FIXED_ROWS + logLines = total.
export const MIN_LOG_LINES = 6;
export const WIDE_LOG_LINES = 3;
export const FIXED_ROWS = NON_TICKET_ROWS + VISIBLE_TICKETS;
layout.logLines = MIN_LOG_LINES;
// Smallest opencode pane (chip + blank + 3-row input + a little transcript) we
// render in the stacked layout, so a short portrait viewport never starves it.
export const OC_MIN_ROWS = 8;
