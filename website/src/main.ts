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

// get-started block — prompt / package-manager tabs + copy. The Prompt tab is
// first and selected by default: it is a line to paste into a coding agent,
// which then reads /llms.txt and walks the user through install and first run.
const AGENT_PROMPT = "Let's run parallel agents with: https://aiur.team/";
const TAB_TEXT: Record<string, string> = {
  prompt: AGENT_PROMPT,
  npm: "npm i -g aiur-cli",
  bun: "bun add -g aiur-cli",
  pnpm: "pnpm add -g aiur-cli",
  yarn: "yarn global add aiur-cli",
};
const installRow = document.getElementById("installRow");
const copyBtn = document.getElementById("copyBtn");
const installWrap = document.getElementById("installWrap");
const nextSteps = document.getElementById("nextSteps");
const installCmd = document.getElementById("installCmd");
const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".pm-tab"));
let activeTab = "prompt";
let command = TAB_TEXT.prompt;
for (const tab of tabs) {
  tab.addEventListener("click", () => {
    activeTab = tab.dataset.pm && tab.dataset.pm in TAB_TEXT ? tab.dataset.pm : "prompt";
    command = TAB_TEXT[activeTab];
    if (installCmd) installCmd.textContent = command;
    const isPrompt = activeTab === "prompt";
    installRow?.classList.toggle("is-prompt", isPrompt);
    copyBtn?.setAttribute("aria-label", isPrompt ? "Copy prompt" : "Copy install command");
    if (isPrompt) {
      installWrap?.classList.remove("show-next");
      nextSteps?.setAttribute("aria-hidden", "true");
    }
    for (const t of tabs) {
      const active = t === tab;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    }
  });
}

// navigator.clipboard is absent outside secure contexts and can reject when
// permission is denied; fall back to a hidden textarea + execCommand so the
// button still copies in those browsers
async function copyText(text: string): Promise<void> {
  try {
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch {
    /* fall through to the legacy path */
  }
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  try {
    document.execCommand("copy");
  } finally {
    ta.remove();
  }
}

copyBtn?.addEventListener("click", () => {
  void copyText(command);
  copyBtn.classList.add("copied");
  setTimeout(() => copyBtn.classList.remove("copied"), 1300);
  // the shell next-steps only follow an install command; after copying the
  // prompt, the user's agent takes it from there
  if (activeTab === "prompt") return;
  installWrap?.classList.add("show-next");
  nextSteps?.setAttribute("aria-hidden", "false");
  document.getElementById("scrollcue")?.classList.add("gone");
});

// nav brand — the splash already shows the logo, so the top-left brand stays
// tucked away while any of the splash is visible below the bar, and slides in
// once the splash has scrolled up behind it. While tucked it is also removed
// from the tab order and the accessibility tree. A page without a splash (or a
// browser without IntersectionObserver) leaves it visible.
const splash = document.querySelector<HTMLElement>(".hero");
const navBar = document.querySelector<HTMLElement>(".topbar");
const brandLink = document.querySelector<HTMLAnchorElement>(".brand-mini");
function setBrandTucked(tucked: boolean): void {
  navBar?.classList.toggle("logo-tucked", tucked);
  if (!brandLink) return;
  if (tucked) {
    brandLink.setAttribute("aria-hidden", "true");
    brandLink.setAttribute("tabindex", "-1");
    // never strand keyboard focus on a control that is sliding out of view
    if (document.activeElement === brandLink) brandLink.blur();
  } else {
    brandLink.removeAttribute("aria-hidden");
    brandLink.removeAttribute("tabindex");
  }
}
if (splash && navBar && brandLink && "IntersectionObserver" in window) {
  // the bar floats over the splash, so "past the splash" means the splash's
  // bottom edge has gone up behind the bar — shrink the root by the bar height
  const barHeight = Math.round(navBar.getBoundingClientRect().height);
  // set the initial state before the first observer callback so the brand
  // does not flash in on load
  setBrandTucked(splash.getBoundingClientRect().bottom > barHeight);
  new IntersectionObserver(
    (entries) => {
      for (const entry of entries) setBrandTucked(entry.isIntersecting);
    },
    { rootMargin: `-${barHeight}px 0px 0px 0px` },
  ).observe(splash);
}

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
