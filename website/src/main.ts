import "./styles.css";
import { initBanner, initBrandReveal, initCommand, initThemeToggle, initTopbarPin, getTheme, setTheme } from "aiur-style";
import { createFlowField } from "aiur-style/field";
import { initTerminal } from "./terminal";

const root = document.documentElement;
setTheme(getTheme());
initThemeToggle(document.querySelector<HTMLButtonElement>("#themeToggle")!);
const banner = document.querySelector<HTMLElement>("#archonBanner")!;
const topbar = document.querySelector<HTMLElement>(".aiur-topbar")!;
initBanner(banner);
initBrandReveal(topbar, { after: ".hero" });
initTopbarPin(topbar, { banner });

const canvas = document.querySelector<HTMLCanvasElement>("#field")!;
const field = createFlowField(canvas);
// Keep the website's existing geometry probe while drawing is owned by the package.
if (root.dataset.fieldDebug !== undefined) {
  canvas.setAttribute("data-aiur-debug", "");
  Object.assign(window, { __field: { debugObstacles: () => field.debug().obstacles } });
}

const wrap = document.querySelector<HTMLElement>("#installWrap")!;
const command = document.querySelector<HTMLElement>(".aiur-command")!;
const nextSteps = document.querySelector<HTMLElement>("#nextSteps")!;
const cue = document.querySelector<HTMLElement>("#scrollcue")!;
initCommand(command, {
  copiedMs: 1300,
  labels: { command: "Copy install command" },
  onCopy: (_text, kind) => {
    if (kind === "prompt") return;
    wrap.classList.add("show-next");
    nextSteps.setAttribute("aria-hidden", "false");
    cue.classList.add("is-gone");
  },
});
command.addEventListener("aiur:layoutchange", () => {
  if (command.dataset.aiurKind !== "prompt") return;
  wrap.classList.remove("show-next");
  nextSteps.setAttribute("aria-hidden", "true");
});

const updateCue = () => cue.classList.toggle("is-gone", window.scrollY > 60);
window.addEventListener("scroll", updateCue, { passive: true });
updateCue();
initTerminal();
