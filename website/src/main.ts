import "./styles.css";
import { createFlowField } from "./flowField";
import { initTerminal } from "./terminal";

const root = document.documentElement;

// storage is unavailable outright in browsers with site data blocked, and every
// access throws there — the page has to keep working without it
function readStored(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function writeStored(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* preference simply is not persisted */
  }
}

// theme — restore saved choice, toggle + persist
const saved = readStored("aiur-theme");
if (saved === "dark" || saved === "light") root.setAttribute("data-theme", saved);
writeStored("aiur-theme", root.getAttribute("data-theme") ?? "dark");

const field = createFlowField();

const themeToggle = document.getElementById("themeToggle");
themeToggle?.addEventListener("click", () => {
  const next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
  root.setAttribute("data-theme", next);
  writeStored("aiur-theme", next);
  field.redraw();
});

// install command — package-manager tabs + copy
const PM_COMMANDS: Record<string, string> = {
  npm: "npm i -g aiur-cli",
  bun: "bun add -g aiur-cli",
  pnpm: "pnpm add -g aiur-cli",
  yarn: "yarn global add aiur-cli",
};
const installCmd = document.getElementById("installCmd");
const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".pm-tab"));
let command = PM_COMMANDS.npm;
for (const tab of tabs) {
  tab.addEventListener("click", () => {
    const pm = tab.dataset.pm ?? "npm";
    command = PM_COMMANDS[pm] ?? PM_COMMANDS.npm;
    if (installCmd) installCmd.textContent = command;
    for (const t of tabs) {
      const active = t === tab;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    }
  });
}

const copyBtn = document.getElementById("copyBtn");
const installWrap = document.getElementById("installWrap");
const nextSteps = document.getElementById("nextSteps");
copyBtn?.addEventListener("click", () => {
  void navigator.clipboard?.writeText(command);
  copyBtn.classList.add("copied");
  setTimeout(() => copyBtn.classList.remove("copied"), 1300);
  installWrap?.classList.add("show-next");
  nextSteps?.setAttribute("aria-hidden", "false");
  document.getElementById("scrollcue")?.classList.add("gone");
});

// announcement strip — dismissal survives reloads, and still works (for this
// page view only) when the browser refuses storage access entirely
document.getElementById("archonDismiss")?.addEventListener("click", () => {
  root.setAttribute("data-archon-banner", "dismissed");
  // when site data is blocked the write is a no-op and the strip simply
  // returns on the next page load, rather than the dismiss control failing
  writeStored("aiur-archon-banner", "dismissed");
});

initTerminal();

// fade the scroll cue out once scrolling begins, and hand the top bar over
// from sticky to fixed once the announcement strip has scrolled away, so it
// keeps floating over the rest of the page the way it always has. The two
// positions coincide at the hand-over point, so the bar never jumps; without
// this the bar would simply stop following at the end of the first screen.
const scrollcue = document.getElementById("scrollcue");
const topbar = document.querySelector(".topbar");
const announce = document.getElementById("archonBanner");
function onScroll(): void {
  const s = window.scrollY || window.pageYOffset || 0;
  scrollcue?.classList.toggle("gone", s > 60);
  // a dismissed strip is display:none, so its rect collapses to zero and the
  // bar pins from the very top, exactly as it did before the strip existed
  const stripBottom = announce?.getBoundingClientRect().bottom ?? 0;
  topbar?.classList.toggle("pinned", stripBottom <= 0);
}
window.addEventListener("scroll", onScroll, { passive: true });
// the browser may restore a scroll position before any scroll event fires
onScroll();
