import {
  TICKETS,
  EVENTS,
  PROJECT,
  ACTIVE,
  MAX,
} from "../simData";
import type { TicketScript, Phase, Agent, EventKind } from "../simData";
import { ABBR, fullGeom, layout, VISIBLE_TICKETS } from "./geometry";
import type { Geom } from "./geometry";
import { SPIN, raw, emo, mark, spin, cat, padEnd, padStart, dashes, trunc, fmtTime, bar } from "./segments";
import type { Seg } from "./segments";

export const PHASE_EMOJI: Record<Phase, string> = {
  brainstorm: "🧠",
  plan: "📋",
  implement: "🛠️",
  review: "🔍",
  done: "🏁",
  blocked: "⏳",
  decide: "❗",
};
export const EVENT_GLYPH: Record<EventKind, string> = {
  publish: "💬",
  receive: "📬",
  read: "📄",
};

const agentSeg = (a: Agent): Seg => raw(a, `ag-${a}`);

export function sample(tk: TicketScript, now: number): {
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

export function ticketRow(
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

export function bordered(content: Seg, g: Geom): string {
  return cat(raw("│ ", "bd"), padEnd(content, g.inner), raw(" │", "bd")).h;
}

export function topBorder(g: Geom): string {
  const left = cat(raw("╭─ ", "bd"), raw("AIUR", "tb"));
  return cat(left, dashes(g.width - left.w - 1), raw("╮", "bd")).h;
}

export function plainDivider(g: Geom): string {
  return cat(raw("├", "bd"), dashes(g.width - 2), raw("┤", "bd")).h;
}

export function logDivider(g: Geom): string {
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

export function bottomBorder(g: Geom): string {
  const label = raw("╰─ newest ", "bd");
  return cat(label, dashes(g.width - label.w - 1), raw("╯", "bd")).h;
}

export function headerRow(label: string, value: string, g: Geom): string {
  return bordered(cat(raw(label), raw(trunc(value, g.inner - label.length), "acc")), g);
}

export function columnHeader(g: Geom): string {
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

export function eventLines(now: number, g: Geom, count: number): string[] {
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
  const g = opts.dropLatest ? ABBR : fullGeom(layout.cols);
  const count = opts.logOverride ?? layout.logLines;
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
