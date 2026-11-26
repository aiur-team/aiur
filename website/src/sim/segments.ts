export const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export interface Seg {
  h: string;
  w: number;
}
export const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
export const raw = (s: string, cls?: string): Seg => ({
  h: cls ? `<span class="${cls}">${esc(s)}</span>` : esc(s),
  w: s.length,
});
export const emo = (ch: string): Seg => ({ h: `<span class="e2">${ch}</span>`, w: 2 });
export const mark = (sel: boolean): Seg => ({
  h: `<span class="e1">${sel ? "▶" : " "}</span>`,
  w: 1,
});
export const spin = (ch: string): Seg => ({ h: `<span class="spin">${ch}</span>`, w: 1 });
export const cat = (...segs: Seg[]): Seg => ({
  h: segs.map((s) => s.h).join(""),
  w: segs.reduce((a, s) => a + s.w, 0),
});
export const padEnd = (seg: Seg, width: number): Seg =>
  seg.w >= width ? seg : cat(seg, raw(" ".repeat(width - seg.w)));
export const padStart = (seg: Seg, width: number): Seg =>
  seg.w >= width ? seg : cat(raw(" ".repeat(width - seg.w)), seg);
export const dashes = (n: number, cls = "bd"): Seg => raw("─".repeat(Math.max(0, n)), cls);

export function trunc(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, Math.max(0, max - 1)) + "…";
}

export function fmtTime(total: number): string {
  const s = total % 60;
  const m = Math.floor(total / 60) % 60;
  const h = Math.floor(total / 3600);
  const ss = String(s).padStart(2, "0");
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${ss}`;
  return `${m}:${ss}`;
}

export function bar(pct: number): Seg {
  const fill = Math.max(0, Math.min(10, Math.round(pct / 10)));
  const full = "█".repeat(fill);
  const empty = "░".repeat(10 - fill);
  return cat(
    full ? raw(full, pct >= 100 ? "ok" : "acc") : raw(""),
    empty ? raw(empty, "bar-empty") : raw(""),
  );
}
