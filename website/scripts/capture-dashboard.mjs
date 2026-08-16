import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { assertSyntheticContent, assertSyntheticMeters } from "./dashboard-capture-safety.mjs";

const websiteRoot = process.cwd();
const repositoryRoot = path.resolve(websiteRoot, "..");
const outputRoot = path.join(
  websiteRoot,
  "public/images/dashboard",
);
const port = await allocatePort();
const baseURL = `http://127.0.0.1:${port}`;

// One capture per documented surface. Every one of them renders the synthetic
// docs fixture only — see `assertSyntheticPage` for the guard that refuses to
// write a file when anything operator-shaped appears on the page.
const surfaces = [
  // `clipHeight` keeps each image to the part of the surface worth documenting;
  // Units is the tall one because the page's point is the fleet table and the
  // Tickets backlog panel below it.
  { name: "units", path: "/", selector: ".dashboard-shell", clipHeight: 1700, marker: "example/ex-142", modelMeters: true },
  { name: "commands", path: "/decisions", selector: ".dashboard-shell", clipHeight: 1250, marker: "dec-example-blocking", modelMeters: false },
  {
    name: "build-orders",
    path: "/build-orders/4200",
    selector: ".dashboard-shell",
    clipHeight: 1400,
    marker: "Example App launch",
    modelMeters: false,
  },
  { name: "streamdeck", path: "/streamdeck", selector: ".dashboard-shell", clipHeight: 900, marker: "EX-142", modelMeters: false },
];

// The fixture guards the financial-data capability behind HTTP Basic auth, and
// the provider meter cards stay locked without it. These are the fixed example
// credentials the fixture installs; they protect a loopback-only test server.
const fixtureCredentials = { username: "example", password: "example" };
const authorizationHeader =
  "Basic " +
  Buffer.from(`${fixtureCredentials.username}:${fixtureCredentials.password}`).toString("base64");

// Identifiers that can only come from the operator's real environment. If any of
// them reach a page the capture aborts rather than writing a checked-in image.
// Provider meters are the known hazard: the production meter source probes the
// operator's own Claude and Codex accounts, so the fixture substitutes a
// synthetic source and these patterns fail the run if a real reading leaks.
// 1280 wide keeps every image at the documented desktop width. The tall
// viewport only exists so a clip can reach a panel below the fold; each surface
// still crops to its own `clipHeight`.
const desktop = { theme: "dark", viewport: { width: 1280, height: 1800 } };

await mkdir(outputRoot, { recursive: true });
const browser = await chromium.launch();

try {
  // Every surface renders from one writable fixture process, so the documented
  // controls appear enabled rather than behind the read-only banner.
  for (const writable of [true]) {
    const selectedSurfaces = surfaces;
    const fixture = startFixture(writable);

    try {
      await waitUntilReady(fixture);

      const context = await browser.newContext({
        colorScheme: desktop.theme,
        deviceScaleFactor: 1,
        httpCredentials: fixtureCredentials,
        viewport: desktop.viewport,
      });

      await context.addInitScript((theme) => {
        window.localStorage.setItem("aiur-theme", theme);
      }, desktop.theme);

      const page = await context.newPage();

      for (const surface of selectedSurfaces) {
        await page.goto(`${baseURL}${surface.path}`, { waitUntil: "networkidle" });
        await page.locator(surface.selector).waitFor({ state: "visible" });
        const html = await assertSyntheticPage(page, surface);
        await assertMetersAreSynthetic(page, surface);

        const output = path.join(outputRoot, `${surface.name}-dark.png`);

        if (surface.clipHeight) {
          const box = await page.locator(surface.selector).boundingBox();
          if (!box) throw new Error(`Could not measure ${surface.selector}`);

          await page.screenshot({
            path: output,
            clip: {
              x: Math.max(box.x, 0),
              y: Math.max(box.y, 0),
              width: Math.min(box.width, desktop.viewport.width),
              height: Math.min(surface.clipHeight, box.height),
            },
          });
        } else {
          await page.locator(surface.selector).screenshot({ path: output });
        }

        process.stdout.write(`captured ${path.relative(repositoryRoot, output)}\n`);
      }

      await context.close();
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
        ANTHROPIC_API_KEY: _anthropicApiKey,
        AIUR_DASHBOARD_PASSWORD: _dashboardPassword,
        AIUR_DASHBOARD_USERNAME: _dashboardUsername,
        AIUR_SUPERVISOR_TOKEN: _supervisorToken,
        DEEPSEEK_API_KEY: _deepseekApiKey,
        ELEVENLABS_API_KEY: _elevenLabsApiKey,
        GITHUB_TOKEN: _githubToken,
        MOONSHOT_API_KEY: _moonshotApiKey,
        OPENAI_API_KEY: _openAiApiKey,
        OPENROUTER_API_KEY: _openRouterApiKey,
        OPENROUTER_MANAGEMENT_KEY: _openRouterManagementKey,
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
      // `/decisions` renders its synthetic Commands straight into the
      // disconnected mount, so it proves the fixture is up AND that it is the
      // example-only fixture rather than a real dashboard on the same port.
      const response = await fetch(`${baseURL}/decisions`, {
        headers: { authorization: authorizationHeader },
      });
      const body = await response.text();

      if (response.ok && body.includes("dec-example-blocking") && body.includes("EX-143")) return;
    } catch {
      // The fixture compiles before its socket starts accepting requests.
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`Fixture did not become ready at ${baseURL}`);
}

async function assertSyntheticPage(page, surface) {
  const html = await page.content();
  const visibleText = await page.locator("body").innerText();
  assertSyntheticContent({ url: page.url(), html, visibleText, marker: surface.marker });

  return html;
}

async function assertMetersAreSynthetic(page, surface) {
  const modelRows = await page.locator(".rs-model").evaluateAll((rows) => rows.map((row) => row.outerHTML));
  assertSyntheticMeters({ url: page.url(), modelRows, required: surface.modelMeters });
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
