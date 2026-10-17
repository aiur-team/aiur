export const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
export const p2 = (n) => String(n).padStart(2, "0");
export const fmtD = (t) => { const d = new Date(t); return MON[d.getMonth()] + " " + d.getDate(); };
export const fmtWD = (t) => { const d = new Date(t); return WD[d.getDay()] + " " + MON[d.getMonth()] + " " + d.getDate(); };
export const fmtT = (t) => { const d = new Date(t); return p2(d.getHours()) + ":" + p2(d.getMinutes()); };
export const dayKey = (t) => { const d = new Date(t); return d.getFullYear() * 400 + d.getMonth() * 32 + d.getDate(); };
export const fmtH = (h) => h < 1 ? Math.max(5, Math.round(h * 60 / 5) * 5) + "m" : h < 10 ? (Math.round(h * 2) / 2) + "h" : Math.round(h) + "h";
export const fmtRange = (a, b) => {
  if (a == null) return "";
  const da = new Date(a), db = new Date(b);
  if (dayKey(a) === dayKey(b)) return fmtD(a);
  if (da.getMonth() === db.getMonth()) return MON[da.getMonth()] + " " + da.getDate() + "–" + db.getDate();
  return fmtD(a) + "–" + fmtD(b);
};
