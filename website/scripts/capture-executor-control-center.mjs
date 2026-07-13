import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";

const websiteRoot = process.cwd();
const repositoryRoot = path.resolve(websiteRoot, "..");
const outputRoot = path.join(
  websiteRoot,
  "public/images/executor-control-center",
);
const port = await allocatePort();
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
      await waitUntilReady(fixture);

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
          await assertSyntheticPage(page);

          if (variant.name === "mobile") await assertNoHorizontalOverflow(page);

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

      await rm(fixture.docsTmp, { force: true, recursive: true });
    }
  }
} finally {
  await browser.close();
}

function startFixture(writable) {
  const docsTmp = path.join(
    tmpdir(),
    `aiur-executor-control-center-docs-${process.pid}-${port}-${writable ? "writable" : "readonly"}`,
  );
  const {
    AIUR_DASHBOARD_PASSWORD: _dashboardPassword,
    AIUR_DASHBOARD_USERNAME: _dashboardUsername,
    AIUR_SUPERVISOR_TOKEN: _supervisorToken,
    ...sanitizedEnvironment
  } = process.env;

  const child = spawn(
    "mise",
    ["exec", "--", "mix", "run", "--no-start", "test/manual/executor_control_center_docs_fixture.exs"],
    {
      cwd: path.join(repositoryRoot, "src"),
      env: {
        ...sanitizedEnvironment,
        AIUR_DOCS_PORT: String(port),
        AIUR_DOCS_TMP: docsTmp,
        AIUR_DOCS_WRITABLE: String(writable),
        AIUR_DASHBOARD_PASSWORD: "",
        AIUR_DASHBOARD_USERNAME: "",
        AIUR_SUPERVISOR_TOKEN: "",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  child.stdout.on("data", (chunk) => process.stdout.write(chunk));
  child.stderr.on("data", (chunk) => process.stderr.write(chunk));
  child.docsTmp = docsTmp;
  return child;
}

async function waitUntilReady(fixture) {
  const deadline = Date.now() + 30_000;

  while (Date.now() < deadline) {
    if (fixture.exitCode !== null) {
      throw new Error(`Fixture exited before readiness with code ${fixture.exitCode}`);
    }

    try {
      const response = await fetch(baseURL);
      const body = await response.text();

      if (response.ok && syntheticMarkerPresent(body)) return;
    } catch {
      // The fixture compiles before its socket starts accepting requests.
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`Fixture did not become ready at ${baseURL}`);
}

async function assertSyntheticPage(page) {
  const html = await page.content();
  const visibleText = await page.locator("body").innerText();

  if (!syntheticMarkerPresent(html)) {
    throw new Error(`Refusing to capture ${page.url()}: synthetic fixture markers are missing`);
  }

  if (visibleText.includes("Human operator")) {
    throw new Error(`Refusing to capture ${page.url()}: legacy human role copy is visible`);
  }
}

async function assertNoHorizontalOverflow(page) {
  const { innerWidth, scrollWidth } = await page.evaluate(() => ({
    innerWidth: window.innerWidth,
    scrollWidth: document.documentElement.scrollWidth,
  }));

  if (scrollWidth > innerWidth) {
    throw new Error(`Mobile page overflows horizontally: ${scrollWidth}px > ${innerWidth}px`);
  }
}

function syntheticMarkerPresent(body) {
  return body.includes("dec-example-blocking") && body.includes("EX-142") && body.includes("memory");
}

async function allocatePort() {
  const server = createServer();

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });

  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Could not allocate an isolated fixture port");

  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });

  return address.port;
}
