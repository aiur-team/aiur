import {
  TICKETS,
  EVENTS,
  LOOP_SECONDS,
  PROJECT,
  ACTIVE,
  MAX,
} from "./simData";
import type { TicketScript, Phase, Agent, EventKind } from "./simData";

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
// Event-log rows. Grown at runtime to fill the terminal's height (see
// startDashboard); every non-log row is fixed, so FIXED_ROWS + logLines = total.
const MIN_LOG_LINES = 6;
const FIXED_ROWS = 21;
let logLines = MIN_LOG_LINES;

const PHASE_EMOJI: Record<Phase, string> = {
  brainstorm: "🧠",
  plan: "📋",
  implement: "🛠️",
  review: "🔍",
  done: "🏁",
  blocked: "⏳",
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

function ticketRow(tk: TicketScript, now: number, spinIdx: number, selected: boolean): string {
  const s = sample(tk, now);
  const timer = tk.seedSec + Math.floor(now);

  const c1 = cat(mark(selected), raw(" ")); // 2
  const c2 = padEnd(raw(String(tk.id)), IDW); // 4
  const c3 = padEnd(agentSeg(tk.agent), AGENTW); // 7
  const c4 = cat(emo(PHASE_EMOJI[s.phase]), raw(" ")); // 3
  const c5 = padEnd(raw(trunc(tk.title, TITLEW - 1)), TITLEW); // 27

  let latestSeg: Seg;
  if (s.phase === "blocked") {
    latestSeg = cat(
      spin(SPIN[spinIdx]),
      raw(" "),
      raw(trunc(s.latest, LATESTW - 3)),
    );
  } else {
    latestSeg = raw(trunc(s.latest, LATESTW - 1));
  }
  const c6 = padEnd(latestSeg, LATESTW); // 33
  const c7 = cat(bar(s.progress), raw(" ")); // 11
  const c8 = padStart(raw(fmtTime(timer), "dim"), TIMEW); // 5

  return bordered(cat(c1, c2, c3, c4, c5, c6, c7, c8));
}

function bordered(content: Seg): string {
  return cat(raw("│ ", "bd"), padEnd(content, INNER), raw(" │", "bd")).h;
}

function topBorder(): string {
  const left = cat(raw("╭─ ", "bd"), raw("AIUR", "tb"));
  return cat(left, dashes(WIDTH - left.w - 1), raw("╮", "bd")).h;
}

function plainDivider(): string {
  return cat(raw("├", "bd"), dashes(WIDTH - 2), raw("┤", "bd")).h;
}

function logDivider(): string {
  const labelW = 8; // " oldest "
  const tail = 2;
  const head = WIDTH - 1 - labelW - tail - 1;
  return cat(
    raw("├", "bd"),
    dashes(head),
    raw(" oldest ", "dim"),
    dashes(tail),
    raw("┤", "bd"),
  ).h;
}

function bottomBorder(): string {
  const label = raw("╰─ newest ", "bd");
  return cat(label, dashes(WIDTH - label.w - 1), raw("╯", "bd")).h;
}

function headerRow(label: string, value: string): string {
  return bordered(cat(raw(label), raw(value, "acc")));
}

function columnHeader(): string {
  return bordered(
    cat(
      raw("  "), // marker
      padEnd(raw("ID", "dim"), IDW),
      padEnd(raw("AGENT", "dim"), AGENTW),
      raw(" ".repeat(STATUSW)),
      padEnd(raw("TITLE", "dim"), TITLEW),
      padEnd(raw("LATEST", "dim"), LATESTW),
      padEnd(raw("PROGRESS", "dim"), PROGW),
      padStart(raw("TIME", "dim"), TIMEW),
    ),
  );
}

function eventLines(now: number): string[] {
  const fired = EVENTS.filter((e) => e.t <= Math.floor(now)).slice(-logLines);
  const lines: string[] = [];
  for (let i = 0; i < logLines - fired.length; i++) lines.push(bordered(raw("")));
  for (const e of fired) {
    const head = cat(
      emo(EVENT_GLYPH[e.kind]),
      raw(" "),
      raw(String(e.id), "acc"),
      raw(" "),
    );
    const text = raw(trunc(e.text, INNER - head.w));
    lines.push(bordered(cat(head, text)));
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

function renderFrame(nowMs: number, baseMs: number): string {
  const loopSec = ((nowMs - baseMs) / 1000) % LOOP_SECONDS;
  const spinIdx = Math.floor(nowMs / 100) % SPIN.length;

  const lines: string[] = [];
  lines.push(topBorder());
  lines.push(headerRow("Agents: ", `${ACTIVE}/${MAX}`));
  lines.push(headerRow("Project: ", PROJECT));
  lines.push(headerRow("Dashboard: ", "http://127.0.0.1:4000/"));
  lines.push(plainDivider());
  lines.push(columnHeader());
  lines.push(plainDivider());
  TICKETS.forEach((tk, i) => lines.push(ticketRow(tk, loopSec, spinIdx, i === 0)));
  lines.push(logDivider());
  for (const l of eventLines(loopSec)) lines.push(l);
  lines.push(bottomBorder());
  lines.push("");
  lines.push(footer());

  return `<pre class="tui-pre">${lines.join("\n")}</pre>`;
}

export function startDashboard(screen: HTMLElement): void {
  const baseMs = performance.now();
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const nowMs = (): number => (reduce ? baseMs + 31_000 : performance.now());

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

  tick();
  fitLogLines();
  tick();

  let rzTimer = 0;
  window.addEventListener("resize", () => {
    clearTimeout(rzTimer);
    rzTimer = window.setTimeout(() => {
      fitLogLines();
      tick();
    }, 150);
  });
  void document.fonts?.ready.then(() => {
    fitLogLines();
    tick();
  });

  if (!reduce) window.setInterval(tick, 100);
}
