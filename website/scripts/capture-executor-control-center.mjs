import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const websiteRoot = process.cwd();
const repositoryRoot = path.resolve(websiteRoot, "..");
const outputRoot = path.join(
  websiteRoot,
  "public/images/executor-control-center",
);
const port = Number(process.env.AIUR_DOCS_PORT || 4099);
const baseURL = `http://127.0.0.1:${port}`;

const surfaces = [
  { name: "overview", path: "/", selector: ".dashboard-shell", clipHeight: 390 },
  { name: "decision-inbox", path: "/decisions", selector: ".decision-inbox" },
  {
    name: "decision",
    path: "/decisions/dec-example-blocking",
    selector: ".decision-card.open",
    writable: true,
  },
  { name: "fleet", path: "/", selector: ".fleet-card" },
  {
    name: "history",
    path: "/",
    selector: "section[aria-labelledby='decision-history-title']",
  },
  { name: "recent-outcomes", path: "/", selector: "#recent-outcomes" },
  {
    name: "analytics-link",
    path: "/",
    selector: "#recent-outcomes .recent-subtitle-row",
  },
];

const variants = [
  { name: "light", theme: "light", viewport: { width: 1280, height: 900 } },
  { name: "dark", theme: "dark", viewport: { width: 1280, height: 900 } },
  { name: "mobile", theme: "dark", viewport: { width: 390, height: 844 } },
];

await mkdir(outputRoot, { recursive: true });
const browser = await chromium.launch();

try {
  for (const writable of [false, true]) {
    const selectedSurfaces = surfaces.filter((surface) => Boolean(surface.writable) === writable);
    const fixture = startFixture(writable);

    try {
      await waitUntilReady();

      for (const variant of variants) {
        const context = await browser.newContext({
          colorScheme: variant.theme,
          deviceScaleFactor: 1,
          viewport: variant.viewport,
        });

        await context.addInitScript((theme) => {
          window.localStorage.setItem("aiur-theme", theme);
        }, variant.theme);

        const page = await context.newPage();

        for (const surface of selectedSurfaces) {
          await page.goto(`${baseURL}${surface.path}`, { waitUntil: "networkidle" });
          await page.locator(surface.selector).waitFor({ state: "visible" });
          const output = path.join(outputRoot, `${surface.name}-${variant.name}.png`);

          if (surface.clipHeight && variant.name !== "mobile") {
            const box = await page.locator(surface.selector).boundingBox();
            if (!box) throw new Error(`Could not measure ${surface.selector}`);

            await page.screenshot({
              path: output,
              clip: {
                x: Math.max(box.x, 0),
                y: Math.max(box.y, 0),
                width: Math.min(box.width, variant.viewport.width),
                height: Math.min(surface.clipHeight, box.height),
              },
            });
          } else {
            await page.locator(surface.selector).screenshot({ path: output });
          }

          process.stdout.write(`captured ${path.relative(repositoryRoot, output)}\n`);
        }

        await context.close();
      }
    } finally {
      if (fixture.exitCode === null) {
        fixture.kill("SIGTERM");
        await once(fixture, "exit");
      }
    }
  }
} finally {
  await browser.close();
}

function startFixture(writable) {
  const child = spawn(
    "mise",
    ["exec", "--", "mix", "run", "--no-start", "test/manual/executor_control_center_docs_fixture.exs"],
    {
      cwd: path.join(repositoryRoot, "src"),
      env: {
        ...process.env,
        AIUR_DOCS_PORT: String(port),
        AIUR_DOCS_WRITABLE: String(writable),
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  child.stdout.on("data", (chunk) => process.stdout.write(chunk));
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  return child;
}

async function waitUntilReady() {
  const deadline = Date.now() + 30_000;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(baseURL);
      if (response.ok) return;
    } catch {
      // The fixture compiles before its socket starts accepting requests.
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`Fixture did not become ready at ${baseURL}`);
}
