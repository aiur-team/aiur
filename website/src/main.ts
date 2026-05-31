import "./styles.css";
import { createFlowField } from "./flowField";
import { initTerminal } from "./terminal";

const root = document.documentElement;

// theme — restore saved choice, toggle + persist
const saved = localStorage.getItem("aiur-theme");
if (saved) root.setAttribute("data-theme", saved);

const field = createFlowField();

const themeToggle = document.getElementById("themeToggle");
themeToggle?.addEventListener("click", () => {
  const next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
  root.setAttribute("data-theme", next);
  localStorage.setItem("aiur-theme", next);
  field.redraw();
});

// copy install command
const copyBtn = document.getElementById("copyBtn");
copyBtn?.addEventListener("click", () => {
  void navigator.clipboard?.writeText("npm i -g aiur");
  copyBtn.classList.add("copied");
  setTimeout(() => copyBtn.classList.remove("copied"), 1300);
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
