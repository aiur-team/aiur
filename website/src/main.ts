import "./styles.css";
import { createFlowField } from "./flowField";
import { initTerminal } from "./terminal";

const root = document.documentElement;

// theme — restore saved choice, toggle + persist
const saved = localStorage.getItem("aiur-theme");
if (saved === "dark" || saved === "light") root.setAttribute("data-theme", saved);
localStorage.setItem("aiur-theme", root.getAttribute("data-theme") ?? "dark");

const field = createFlowField();

const themeToggle = document.getElementById("themeToggle");
themeToggle?.addEventListener("click", () => {
  const next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
  root.setAttribute("data-theme", next);
  localStorage.setItem("aiur-theme", next);
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

initTerminal();

// fade the scroll cue out once scrolling begins
const scrollcue = document.getElementById("scrollcue");
window.addEventListener(
  "scroll",
  () => {
    const s = window.scrollY || window.pageYOffset || 0;
    scrollcue?.classList.toggle("gone", s > 60);
  },
  { passive: true },
);
