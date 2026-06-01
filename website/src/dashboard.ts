import {
  TICKETS,
  EVENTS,
  LOOP_SECONDS,
  PROJECT,
  ACTIVE,
  MAX,
  BEAT,
  OC_TOTAL_ROWS,
  OPENCODE_SCRIPT,
} from "./simData";
import type { TicketScript, Phase, Agent, EventKind, OcLine } from "./simData";

// ---- frame geometry (character columns) ----
const MARKER = 2;
const IDW = 4;
const AGENTW = 7;
const STATUSW = 3;
const TITLEW = 24;
const LATESTW = 28;
const PROGW = 11;
const TIMEW = 5;
const INNER = MARKER + IDW + AGENTW + STATUSW + TITLEW + LATESTW + PROGW + TIMEW; // 84
const WIDTH = INNER + 4; // 88 incl. "│ " and " │"

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
// dashboard during the beat. Width is derived so the combined split
// (dashboard + gutter + pane) equals WIDTH, keeping the container-query font
// ratio unchanged (no overflow/clip). No rail: every pane row fills OC_PANE_W.
export const OC_GUTTER = 1; // blank cols between dashboard box and pane
export const OC_PANE_W = WIDTH - DASH_BOX_W_ABBR - OC_GUTTER; // 57
// Show the top slice of the fleet so the grid fills width without the rows
// overflowing the terminal's height at large font sizes.
const VISIBLE_TICKETS = 6;
// Rows that aren't tickets or log lines: top border, 3 header rows, 2 dividers,
// column header, log divider, bottom border.
const NON_TICKET_ROWS = 9;
// Event-log rows. On narrow screens this grows at runtime to fill the
// terminal's vertical slack (see startDashboard); on wide screens it's pinned
// low so the grid stays compact and vertically centered. Every non-log row is
// fixed, so FIXED_ROWS + logLines = total.
const MIN_LOG_LINES = 6;
const WIDE_LOG_LINES = 3;
const FIXED_ROWS = NON_TICKET_ROWS + VISIBLE_TICKETS;
let logLines = MIN_LOG_LINES;
// Desktop-width flag. Drives the pinned 3-line log section and the
// side-by-side beat split. Set by chooseLayout from the viewport width.
let wide = true;

const PHASE_EMOJI: Record<Phase, string> = {
  brainstorm: "🧠",
  plan: "📋",
  implement: "🛠️",
  review: "🔍",
  done: "🏁",
  blocked: "⏳",
  decide: "❗",
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
  // status cell: when LATEST is dropped, a spinner stands in for a blocked row.
  // decide keeps its ❗ emoji (the surfaced-decision marker) in both geometries.
  cols.push(
    g.dropLatest && s.phase === "blocked"
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
// Every pane row is exactly OC_PANE_W cols. No rail/box chrome: opencode's
// turns are delineated by background-tinted bands (oc-userblock / oc-field),
// an accent gutter glyph on cmd/tool lines, and plain prose otherwise.
const ocPad = (content: Seg): Seg => padEnd(content, OC_PANE_W);
const ocPlain = (content: Seg): string => ocPad(content).h;
const ocBlank = (): string => ocPlain(raw(""));

// A full-width background band: pad to OC_PANE_W *inside* the wrapping span so
// the background color covers the whole row (literal padding chars, not CSS
// width), keeping the Seg width model and the assert in agreement.
function ocBand(content: Seg, cls: string): string {
  return `<span class="${cls}">${ocPad(content).h}</span>`;
}

const ocGutter = (): Seg => ({ h: `<span class="oc-gutter">│</span>`, w: 1 });
const ocCursor = (): Seg => ({ h: `<span class="cursor"></span>`, w: 1 });
// Solid one-column accent bar for the banded rows (input field + posted user
// block). CSS gives the cell a filled background so the bands read as a single
// left rail rather than per-row glyphs.
const ocBar = (): Seg => ({ h: `<span class="oc-bar"> </span>`, w: 1 });

function ocHistory(line: OcLine): string {
  switch (line.kind) {
    case "cmd":
      return ocPlain(cat(ocGutter(), raw(" "), raw(trunc(line.text, OC_PANE_W - 2), "oc-cmd")));
    case "tool":
      return ocPlain(cat(ocGutter(), raw(" "), raw(trunc(line.text, OC_PANE_W - 2), "oc-tool")));
    case "prose":
      return ocPlain(raw(trunc(line.text, OC_PANE_W)));
  }
}

// Operator typing: deterministic per-char reveal offsets (seconds from
// typeStart), seeded so the same loopSec always yields the same substring
// (R-V4/R-V9). Speed varies ~80–120ms/char but is a pure function of index.
const TYPE_OFFSETS: number[] = (() => {
  const offs: number[] = [];
  let t = 0;
  for (let i = 0; i < OPENCODE_SCRIPT.typedText.length; i++) {
    const r = ((i * 2654435761) >>> 0) % 100; // 0..99, deterministic
    t += 0.08 + (r / 99) * 0.04;
    offs.push(t);
  }
  return offs;
})();

function revealedInput(loopSec: number): string {
  const elapsed = loopSec - BEAT.typeStart;
  let n = 0;
  for (const o of TYPE_OFFSETS) if (o <= elapsed) n++;
  return OPENCODE_SCRIPT.typedText.slice(0, n);
}

// Three-row filled input field with a solid accent left bar: a blank row, the
// typed substring + blinking cursor (while [typeStart, sendAt); just the cursor
// otherwise), and the dim context label. At sendAt the text posts as an
// oc-userblock above (see builder). The leading blank row gives the box height.
function ocInputField(loopSec: number): string[] {
  const typing = loopSec >= BEAT.typeStart && loopSec < BEAT.sendAt;
  const shown = typing ? revealedInput(loopSec) : "";
  const blank = cat(ocBar(), raw(" "));
  const prompt = cat(
    ocBar(),
    raw(" "),
    raw("› ", "oc-prompt"),
    raw(trunc(shown, OC_PANE_W - 5)),
    ocCursor(),
  );
  const label = cat(
    ocBar(),
    padStart(raw(trunc(OPENCODE_SCRIPT.inputLabel, OC_PANE_W - 3), "dim"), OC_PANE_W - 2),
    raw(" "),
  );
  return [
    ocBand(blank, "oc-field"),
    ocBand(prompt, "oc-field"),
    ocBand(label, "oc-field"),
  ];
}

// The posted operator message — a full-width tinted band with the solid bar.
function ocUserBlock(text: string): string {
  return ocBand(cat(ocBar(), raw(" "), raw(trunc(text, OC_PANE_W - 2))), "oc-userblock");
}

// The scrollback transcript in chronological order (oldest first). The history
// + alert + question head are present the moment the pane opens (R-V on-open);
// the three options post one-per-second from optStart, each with a greyed
// elaboration; the operator's posted block lands at sendAt and the reply at
// replyAt. The renderer bottom-anchors this list so the newest line sits just
// above the input and older lines scroll off the top (real opencode behavior).
function ocTranscript(loopSec: number): string[] {
  const s = OPENCODE_SCRIPT;
  const lines: string[] = [];
  for (const h of s.history) lines.push(ocHistory(h));
  lines.push(ocBlank());
  lines.push(ocPlain(cat(emo("❗"), raw(" "), raw(trunc(s.alertText, OC_PANE_W - 3)))));
  lines.push(ocPlain(raw(trunc(s.questionHead, OC_PANE_W))));
  s.options.forEach((opt, i) => {
    if (loopSec >= BEAT.optStart + i) {
      lines.push(ocPlain(raw(trunc(opt.label, OC_PANE_W))));
      lines.push(ocPlain(raw("   " + trunc(opt.detail, OC_PANE_W - 3), "oc-dim")));
    }
  });
  if (loopSec >= BEAT.sendAt) {
    lines.push(ocBlank());
    lines.push(ocUserBlock(s.typedText));
  }
  if (loopSec >= BEAT.replyAt) {
    lines.push(ocBlank());
    lines.push(ocPlain(raw(trunc(s.reply, OC_PANE_W))));
  }
  return lines;
}

// Render the opencode pane as a fixed-height array of OC_PANE_W-col rows
// (`rows` total). Pure function of loopSec/spinIdx; the join in renderFrame
// stitches it beside the abbreviated dashboard. Turns appear whole on the 1Hz
// repaint; only the operator's input types char-by-char (R-V4) and the chip
// spinner ticks. The transcript is bottom-anchored: when it is shorter than the
// pane the top is padded with blanks; when longer, the oldest lines scroll off.
export function buildOpencodeLines(
  loopSec: number,
  spinIdx: number,
  rows: number = OC_TOTAL_ROWS,
): string[] {
  const s = OPENCODE_SCRIPT;
  const chip = cat(
    raw("▣ ", "oc-chip"),
    raw(s.chip, "oc-chip"),
    raw("  "),
    spin(SPIN[spinIdx]),
  );

  const field = ocInputField(loopSec);
  // minus chip + one separator blank + input field
  const transcriptRows = rows - 2 - field.length;
  const transcript = ocTranscript(loopSec).slice(-transcriptRows);
  while (transcript.length < transcriptRows) transcript.unshift(ocBlank());

  return [ocPlain(chip), ...transcript, ocBlank(), ...field];
}

// The ticket the operator "takes the wheel" on during the beat (R3).
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
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: true,
      selectedId: DRIVEN_ID,
    });
    body = joinColumns(dash, buildOpencodeLines(loopSec, spinIdx));
  } else {
    // Stacked (narrow portrait): the opencode pane is the focus and should claim
    // roughly the bottom two-thirds. Render a compact dashboard (one log line)
    // on top, then a pane sized to ~2x the dashboard height below the rule.
    const dash = buildDashboardLines(loopSec, spinIdx, {
      dropLatest: false,
      selectedId: DRIVEN_ID,
      logOverride: 1,
    });
    const pane = buildOpencodeLines(loopSec, spinIdx, dash.length * 2);
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

  // Wide flag + side-by-side-vs-stacked for the beat split. Both layouts render
  // the same 96-col grid width, so the split choice is readability/aspect, not
  // fit. Stack only on a truly narrow portrait viewport — landscape and medium
  // widths keep the dashboard and pane side by side (a hysteresis dead-band of
  // 600–680px prevents flip-flop near the threshold).
  const chooseLayout = (): void => {
    const w = screen.getBoundingClientRect().width;
    const portrait = window.matchMedia("(orientation: portrait)").matches;
    wide = w >= 700;
    if (!portrait || w >= 680) sideBySide = true;
    else if (w < 600) sideBySide = false;
  };

  const tick = (): void => {
    screen.innerHTML = renderFrame(nowMs(), baseMs);
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
    const lineH = pre.getBoundingClientRect().height / (FIXED_ROWS + logLines);
    const avail = screen.clientHeight;
    if (lineH > 0 && avail > 0) {
      logLines = Math.max(floorLines, Math.floor(avail / lineH) - FIXED_ROWS);
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
