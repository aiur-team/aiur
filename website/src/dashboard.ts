import {
  TICKETS,
  EVENTS,
  LOOP_SECONDS,
  PROJECT,
  ACTIVE,
  MAX,
  BEAT,
  OPENCODE_SCRIPT,
} from "./simData";
import type { TicketScript, Phase, Agent, EventKind, OcLine } from "./simData";

// ---- frame geometry (character columns) ----
const MARKER = 2;
const IDW = 4;
const AGENTW = 7;
const STATUSW = 3;
const TITLEW = 27;
const LATESTW = 33;
const PROGW = 11;
const TIMEW = 5;
const INNER = MARKER + IDW + AGENTW + STATUSW + TITLEW + LATESTW + PROGW + TIMEW; // 92
const WIDTH = INNER + 4; // 96 incl. "│ " and " │"

// Two dashboard geometries. FULL is today's full-width grid. ABBR is the
// ~1/3-width pane shown beside the opencode pane during the take-the-wheel
// beat: AGENT, LATEST and TIME columns drop, TITLE truncates, and PROGRESS
// becomes a percentage so the combined split stays within the ~96-col budget.
interface Geom {
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
const FULL: Geom = {
  id: IDW, agent: AGENTW, status: STATUSW, title: TITLEW,
  latest: LATESTW, prog: PROGW, time: TIMEW,
  inner: INNER, width: WIDTH, dropLatest: false,
};
const TITLE_S = 11;
const PROG_S = 6;
const INNER_S = MARKER + IDW + STATUSW + TITLE_S + PROG_S; // 26
const ABBR: Geom = {
  id: IDW, agent: 0, status: STATUSW, title: TITLE_S,
  latest: 0, prog: PROG_S, time: 0,
  inner: INNER_S, width: INNER_S + 4, dropLatest: true,
};
export const DASH_BOX_W = WIDTH;
export const DASH_BOX_W_ABBR = INNER_S + 4;

// opencode pane geometry. The pane sits to the right of the abbreviated
// dashboard during the beat: a left rail, then OC_INNER content cols. Widths
// are derived so the combined split (dashboard + gutter + pane) equals WIDTH,
// keeping the container-query font ratio unchanged (no overflow/clip).
const OC_RAIL_W = 2; // "┃ "
export const OC_GUTTER = 1; // blank cols between dashboard box and pane
export const OC_INNER = WIDTH - DASH_BOX_W_ABBR - OC_GUTTER - OC_RAIL_W; // 63
export const OC_PANE_W = OC_RAIL_W + OC_INNER; // 65
// Show the top slice of the fleet so the grid fills width without the rows
// overflowing the terminal's height at large font sizes.
const VISIBLE_TICKETS = 6;
// Rows that aren't tickets or log lines: top border, 3 header rows, 2 dividers,
// column header, log divider, bottom border, spacer, footer.
const NON_TICKET_ROWS = 11;
// Event-log rows. Grown at runtime to fill the terminal's height (see
// startDashboard); every non-log row is fixed, so FIXED_ROWS + logLines = total.
const MIN_LOG_LINES = 6;
const FIXED_ROWS = NON_TICKET_ROWS + VISIBLE_TICKETS;
let logLines = MIN_LOG_LINES;

const PHASE_EMOJI: Record<Phase, string> = {
  brainstorm: "🧠",
  plan: "📋",
  implement: "🛠️",
  review: "🔍",
  done: "🏁",
  blocked: "⏳",
  decide: "✋",
};
const EVENT_GLYPH: Record<EventKind, string> = {
  publish: "💬",
  receive: "📬",
  read: "📄",
};
const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

// ---- width-aware segment builder ----
interface Seg {
  h: string;
  w: number;
}
const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const raw = (s: string, cls?: string): Seg => ({
  h: cls ? `<span class="${cls}">${esc(s)}</span>` : esc(s),
  w: s.length,
});
const emo = (ch: string): Seg => ({ h: `<span class="e2">${ch}</span>`, w: 2 });
const mark = (sel: boolean): Seg => ({
  h: `<span class="e1">${sel ? "▶" : " "}</span>`,
  w: 1,
});
const spin = (ch: string): Seg => ({ h: `<span class="spin">${ch}</span>`, w: 1 });
const cat = (...segs: Seg[]): Seg => ({
  h: segs.map((s) => s.h).join(""),
  w: segs.reduce((a, s) => a + s.w, 0),
});
const padEnd = (seg: Seg, width: number): Seg =>
  seg.w >= width ? seg : cat(seg, raw(" ".repeat(width - seg.w)));
const padStart = (seg: Seg, width: number): Seg =>
  seg.w >= width ? seg : cat(raw(" ".repeat(width - seg.w)), seg);
const dashes = (n: number, cls = "bd"): Seg => raw("─".repeat(Math.max(0, n)), cls);

function trunc(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, Math.max(0, max - 1)) + "…";
}

function fmtTime(total: number): string {
  const s = total % 60;
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  const ss = String(s).padStart(2, "0");
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${ss}`;
  return `${m}:${ss}`;
}

function bar(pct: number): Seg {
  const fill = Math.max(0, Math.min(10, Math.round(pct / 10)));
  const full = "█".repeat(fill);
  const empty = "░".repeat(10 - fill);
  return cat(
    full ? raw(full, pct >= 100 ? "ok" : "acc") : raw(""),
    empty ? raw(empty, "bar-empty") : raw(""),
  );
}

const agentSeg = (a: Agent): Seg => raw(a, `ag-${a}`);

function sample(tk: TicketScript, now: number): {
  phase: Phase;
  latest: string;
  progress: number;
} {
  const f = tk.frames;
  let i = 0;
  for (let k = 0; k < f.length; k++) {
    if (f[k].t <= now) i = k;
    else break;
  }
  const cur = f[i];
  const nxt = f[i + 1];
  let progress = cur.progress;
  if (nxt) {
    const span = nxt.t - cur.t;
    const r = span > 0 ? Math.min(1, Math.max(0, (now - cur.t) / span)) : 1;
    progress = cur.progress + (nxt.progress - cur.progress) * r;
  }
  // Keep the LATEST cell in lockstep with the event log: if this ticket has
  // published an event more recently than its active frame, show that text.
  let latest = cur.latest;
  let latestT = cur.t;
  for (const e of EVENTS) {
    if (e.id === tk.id && e.t <= now && e.t >= latestT) {
      latest = e.text;
      latestT = e.t;
    }
  }
  return { phase: cur.phase, latest, progress };
}

function ticketRow(
  tk: TicketScript,
  now: number,
  spinIdx: number,
  selected: boolean,
  g: Geom,
): string {
  const s = sample(tk, now);
  const timer = tk.seedSec + Math.floor(now);
  const stalled = s.phase === "blocked" || s.phase === "decide";

  const cols: Seg[] = [cat(mark(selected), raw(" "))]; // marker 2
  cols.push(padEnd(raw(String(tk.id)), g.id));
  if (g.agent) cols.push(padEnd(agentSeg(tk.agent), g.agent));
  // status cell: when LATEST is dropped, the spinner lives here for stalled rows
  cols.push(
    g.dropLatest && stalled
      ? cat(spin(SPIN[spinIdx]), raw("  "))
      : cat(emo(PHASE_EMOJI[s.phase]), raw(" ")),
  ); // width = status (3)
  cols.push(padEnd(raw(trunc(tk.title, g.title - 1)), g.title));
  if (!g.dropLatest) {
    const latestSeg = stalled
      ? cat(spin(SPIN[spinIdx]), raw(" "), raw(trunc(s.latest, g.latest - 3)))
      : raw(trunc(s.latest, g.latest - 1));
    cols.push(padEnd(latestSeg, g.latest));
  }
  cols.push(
    g.dropLatest
      ? padStart(raw(`${Math.round(s.progress)}%`, s.progress >= 100 ? "ok" : "acc"), g.prog)
      : cat(bar(s.progress), raw(" ")),
  );
  if (g.time) cols.push(padStart(raw(fmtTime(timer), "dim"), g.time));

  return bordered(cat(...cols), g);
}

function bordered(content: Seg, g: Geom): string {
  return cat(raw("│ ", "bd"), padEnd(content, g.inner), raw(" │", "bd")).h;
}

function topBorder(g: Geom): string {
  const left = cat(raw("╭─ ", "bd"), raw("AIUR", "tb"));
  return cat(left, dashes(g.width - left.w - 1), raw("╮", "bd")).h;
}

function plainDivider(g: Geom): string {
  return cat(raw("├", "bd"), dashes(g.width - 2), raw("┤", "bd")).h;
}

function logDivider(g: Geom): string {
  const labelW = 8; // " oldest "
  const tail = 2;
  const head = g.width - 1 - labelW - tail - 1;
  return cat(
    raw("├", "bd"),
    dashes(head),
    raw(" oldest ", "dim"),
    dashes(tail),
    raw("┤", "bd"),
  ).h;
}

function bottomBorder(g: Geom): string {
  const label = raw("╰─ newest ", "bd");
  return cat(label, dashes(g.width - label.w - 1), raw("╯", "bd")).h;
}

function headerRow(label: string, value: string, g: Geom): string {
  return bordered(cat(raw(label), raw(trunc(value, g.inner - label.length), "acc")), g);
}

function columnHeader(g: Geom): string {
  const cols: Seg[] = [raw("  ")]; // marker
  cols.push(padEnd(raw("ID", "dim"), g.id));
  if (g.agent) cols.push(padEnd(raw("AGENT", "dim"), g.agent));
  cols.push(raw(" ".repeat(g.status)));
  cols.push(padEnd(raw("TITLE", "dim"), g.title));
  if (!g.dropLatest) cols.push(padEnd(raw("LATEST", "dim"), g.latest));
  cols.push(
    g.dropLatest
      ? padStart(raw("PROG", "dim"), g.prog)
      : padEnd(raw("PROGRESS", "dim"), g.prog),
  );
  if (g.time) cols.push(padStart(raw("TIME", "dim"), g.time));
  return bordered(cat(...cols), g);
}

function eventLines(now: number, g: Geom, count: number): string[] {
  const fired = EVENTS.filter((e) => e.t <= Math.floor(now)).slice(-count);
  const lines: string[] = [];
  for (let i = 0; i < count - fired.length; i++) lines.push(bordered(raw(""), g));
  for (const e of fired) {
    const head = cat(
      emo(EVENT_GLYPH[e.kind]),
      raw(" "),
      raw(String(e.id), "acc"),
      raw(" "),
    );
    const text = raw(trunc(e.text, g.inner - head.w));
    lines.push(bordered(cat(head, text), g));
  }
  return lines;
}

function footer(): string {
  const keys = raw(
    "  ↑/↓ select   enter open   space pause   v layout   ? help   q quit",
    "dim",
  );
  return keys.h;
}

// Build the dashboard box (top border → bottom border) as an array of line
// strings. Default output (dropLatest:false, no selectedId) is byte-identical
// to the historical full-width frame; the assert script locks that invariant.
export function buildDashboardLines(
  loopSec: number,
  spinIdx: number,
  opts: { dropLatest: boolean; selectedId?: number; logOverride?: number },
): string[] {
  const g = opts.dropLatest ? ABBR : FULL;
  const count = opts.logOverride ?? logLines;
  const lines: string[] = [];
  lines.push(topBorder(g));
  lines.push(headerRow("Agents: ", `${ACTIVE}/${MAX}`, g));
  lines.push(headerRow("Project: ", PROJECT, g));
  lines.push(headerRow("Dashboard: ", "http://127.0.0.1:4000/", g));
  lines.push(plainDivider(g));
  lines.push(columnHeader(g));
  lines.push(plainDivider(g));
  TICKETS.slice(0, VISIBLE_TICKETS).forEach((tk, i) => {
    const selected = opts.selectedId != null ? tk.id === opts.selectedId : i === 0;
    lines.push(ticketRow(tk, loopSec, spinIdx, selected, g));
  });
  lines.push(logDivider(g));
  for (const l of eventLines(loopSec, g, count)) lines.push(l);
  lines.push(bottomBorder(g));
  return lines;
}

// ---- opencode pane (the "take the wheel" beat) ----
const ocRail = (): Seg => raw("┃ ", "oc-rail");

// Wrap a content Seg into a full pane row: rail + content padded to OC_INNER.
function ocRow(content: Seg): string {
  return cat(ocRail(), padEnd(content, OC_INNER)).h;
}

function ocBlank(): string {
  return ocRow(raw(""));
}

function ocTranscript(line: OcLine): string {
  switch (line.kind) {
    case "cmd":
      return ocRow(cat(raw("$ ", "oc-cmd"), raw(trunc(line.text, OC_INNER - 2), "oc-cmd")));
    case "tool":
      return ocRow(cat(raw("→ ", "oc-tool"), raw(trunc(line.text, OC_INNER - 2), "oc-tool")));
    case "ack":
      return ocRow(cat(emo("👍"), raw(" "), raw(trunc(line.text, OC_INNER - 3))));
    case "prose":
      return ocRow(raw(trunc(line.text, OC_INNER)));
  }
}

// Three/four-row char-art input box, each row exactly OC_INNER cols wide.
function ocInputBox(loopSec: number): string[] {
  const s = OPENCODE_SCRIPT;
  const decided = loopSec >= s.decisionAt;
  const bar = (l: string, r: string): string =>
    ocRow(cat(raw(l, "bd"), dashes(OC_INNER - 2), raw(r, "bd")));
  const inner = (body: Seg): string =>
    ocRow(
      cat(
        raw("│", "oc-input"),
        raw(" "),
        padEnd(body, OC_INNER - 4),
        raw(" "),
        raw("│", "oc-input"),
      ),
    );
  const prompt = cat(
    raw("› ", "oc-input"),
    decided ? raw(trunc(s.decisionText, OC_INNER - 6)) : raw(""),
  );
  const label = raw(trunc(s.inputLabel, OC_INNER - 4), "dim");
  return [bar("┌", "┐"), inner(prompt), inner(label), bar("└", "┘")];
}

function ocFooter(): string {
  return ocRow(
    cat(
      raw("▣▣▣▢▢ ", "oc-chip"),
      raw("esc interrupt   tab agents   ctrl+p commands", "dim"),
    ),
  );
}

// Render the opencode pane as full-width pane rows (OC_PANE_W cols each).
// Pure function of loopSec/spinIdx; the join in renderFrame stitches it beside
// the abbreviated dashboard. Lines appear whole on the 1Hz repaint (no
// typewriter); the chip spinner is the only sub-second motion (R7/AE3).
export function buildOpencodeLines(loopSec: number, spinIdx: number): string[] {
  const s = OPENCODE_SCRIPT;
  const done = loopSec >= s.chipDoneAt;
  const chip = cat(
    done ? raw("▣ ", "oc-chip") : cat(spin(SPIN[spinIdx]), raw(" ")),
    raw(s.chip, "oc-chip"),
    done ? raw(" · done", "dim") : raw(""),
  );

  const lines: string[] = [ocRow(chip), ocBlank()];
  // Fixed-height transcript: fired lines fill from the top, remaining slots are
  // blank, so the pane's row count never changes mid-beat (the input box and
  // footer hold their position and the split height stays stable).
  const fired = s.lines.filter((l) => l.t <= Math.floor(loopSec));
  for (const line of fired) lines.push(ocTranscript(line));
  for (let i = fired.length; i < s.lines.length; i++) lines.push(ocBlank());
  lines.push(ocBlank());
  for (const l of ocInputBox(loopSec)) lines.push(l);
  lines.push(ocBlank());
  lines.push(ocFooter());
  return lines;
}

// The ticket the operator "takes the wheel" on during the beat (R3).
const DRIVEN_ID = 321;

// Layout flag for the beat split: side-by-side when the viewport is wide
// enough, stacked otherwise. Resize-driven module state (not loop-driven) so
// renderFrame is a pure read — see chooseLayout for the hysteresis band.
let sideBySide = true;

// Stitch the abbreviated dashboard (left) beside the opencode pane (right).
// Left rows are already DASH_BOX_W_ABBR wide and right rows OC_PANE_W, so each
// joined row is exactly WIDTH cols. The shorter column is padded with blank,
// full-width rows so borders stay aligned and the height matches the dashboard.
export function joinColumns(left: string[], right: string[]): string[] {
  const blankL = " ".repeat(DASH_BOX_W_ABBR);
  const blankR = " ".repeat(OC_PANE_W);
  const gutter = " ".repeat(OC_GUTTER);
  const rows = Math.max(left.length, right.length);
  const out: string[] = [];
  for (let i = 0; i < rows; i++) {
    out.push((left[i] ?? blankL) + gutter + (right[i] ?? blankR));
  }
  return out;
}

function stackRule(): string {
  return dashes(WIDTH, "bd").h;
}

export function renderFrame(nowMs: number, baseMs: number): string {
  const loopSec = ((nowMs - baseMs) / 1000) % LOOP_SECONDS;
  const spinIdx = Math.floor(nowMs / 100) % SPIN.length;
  const inBeat = loopSec >= BEAT.open && loopSec < BEAT.close;

  let body: string[];
  if (!inBeat) {
    body = buildDashboardLines(loopSec, spinIdx, { dropLatest: false });
  } else if (sideBySide) {
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: true,
      selectedId: DRIVEN_ID,
    });
    body = joinColumns(dash, buildOpencodeLines(loopSec, spinIdx));
  } else {
    // Stacked (narrow): full-width dashboard on top, rule, then the pane below.
    // Shrink the dashboard's log lines by the pane+rule height so the total
    // row count matches the non-beat frame (no vertical jump).
    const pane = buildOpencodeLines(loopSec, spinIdx);
    const reduced = Math.max(MIN_LOG_LINES, logLines - 1 - pane.length);
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: false,
      selectedId: DRIVEN_ID,
      logOverride: reduced,
    });
    body = [...dash, stackRule(), ...pane];
  }

  const lines = [...body, "", footer()];
  return `<pre class="tui-pre">${lines.join("\n")}</pre>`;
}

export function startDashboard(screen: HTMLElement): void {
  const baseMs = performance.now();
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Reduced-motion freezes one frame inside the beat: loopSec ≈ 28 lands after
  // the t=26 publish, with the decision in the input box, the chip showing
  // "· done" (chipDoneAt=28, so no frozen spinner), and #321 resuming (R11).
  const nowMs = (): number => (reduce ? baseMs + 28_000 : performance.now());

  // Side-by-side vs stacked for the beat split. Both layouts render the same
  // 96-col grid width, so this is a readability/aspect choice, not a fit one.
  // Hysteresis dead-band (600–720px) prevents flip-flop near the threshold.
  const chooseLayout = (): void => {
    const w = screen.getBoundingClientRect().width;
    if (w >= 720) sideBySide = true;
    else if (w < 600) sideBySide = false;
  };

  const tick = (): void => {
    screen.innerHTML = renderFrame(nowMs(), baseMs);
  };

  // The TUI is a fixed-width grid: its font shrinks to fit width, so on narrow
  // screens it leaves vertical slack. Grow the log section to fill that slack.
  // Line height tracks width (font-size) only, so it's stable across row counts.
  const fitLogLines = (): void => {
    const pre = screen.querySelector(".tui-pre") as HTMLElement | null;
    if (!pre) return;
    const lineH = pre.getBoundingClientRect().height / (FIXED_ROWS + logLines);
    const avail = screen.clientHeight;
    if (lineH > 0 && avail > 0) {
      logLines = Math.max(MIN_LOG_LINES, Math.floor(avail / lineH) - FIXED_ROWS);
    }
  };

  chooseLayout();
  tick();
  fitLogLines();
  tick();

  let rzTimer = 0;
  window.addEventListener("resize", () => {
    clearTimeout(rzTimer);
    rzTimer = window.setTimeout(() => {
      chooseLayout();
      fitLogLines();
      tick();
    }, 150);
  });
  void document.fonts?.ready.then(() => {
    chooseLayout();
    fitLogLines();
    tick();
  });

  if (!reduce) window.setInterval(tick, 100);
}
