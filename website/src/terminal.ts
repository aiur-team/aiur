import { startDashboard } from "./dashboard";

// Kicks off the terminal dashboard animation when it scrolls into view.
export function initTerminal(): void {
  const terminalEl = document.getElementById("terminal");
  if (!terminalEl) return;

  let started = false;
  function startTerminalAnim(): void {
    if (started) return;
    started = true;
    terminalEl!.classList.add("live");
    const screen = document.getElementById("termScreen");
    if (screen) startDashboard(screen);
  }

  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((en) => {
          if (en.isIntersecting && en.intersectionRatio >= 0.55) startTerminalAnim();
        });
      },
      { threshold: [0, 0.55, 1] },
    );
    io.observe(terminalEl);
  } else {
    startTerminalAnim();
  }
}
