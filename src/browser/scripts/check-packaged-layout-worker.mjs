import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { chromium } from 'playwright'

function fail(message) {
  throw new Error(`check-packaged-layout-worker: ${message}`)
}

function releaseArgument(argv) {
  if (argv.length !== 2 || argv[0] !== '--release') fail('usage: --release <dir>')
  return path.resolve(argv[1])
}

function findAiurApplication(release) {
  const applications = path.join(release, 'lib')
  if (!existsSync(applications)) fail(`release lib directory is missing: ${applications}`)

  const aiurApplication = readdirSync(applications).find((entry) => entry.startsWith('aiur-'))
  if (!aiurApplication) fail('release does not contain an aiur application directory')

  return path.join(applications, aiurApplication)
}

function findVendor(aiurApplication) {
  const vendor = path.join(aiurApplication, 'priv', 'static', 'vendor', 'elk', '0.11.1')
  if (!existsSync(vendor)) fail('release does not contain the ELK vendor directory')
  return vendor
}

function readStaticAssets(aiurApplication) {
  const staticRoot = path.join(aiurApplication, 'priv', 'static')
  const modules = [
    ['/dashboard.css', 'dashboard.css', 'text/css'],
    ['/aiur-dom-svg-layout-loader.js', 'aiur-dom-svg-layout-loader.js', 'application/javascript'],
    ['/aiur-dom-svg-layout-adapter.js', 'aiur-dom-svg-layout-adapter.js', 'application/javascript'],
    ['/aiur-dom-svg-layout/lifecycle.js', 'aiur-dom-svg-layout/lifecycle.js', 'application/javascript'],
    ['/aiur-dom-svg-layout/measurement.js', 'aiur-dom-svg-layout/measurement.js', 'application/javascript'],
    ['/aiur-dom-svg-layout/protocol.js', 'aiur-dom-svg-layout/protocol.js', 'application/javascript'],
    ['/aiur-dom-svg-layout/renderer.js', 'aiur-dom-svg-layout/renderer.js', 'application/javascript']
  ]

  const assets = new Map()
  for (const [url, file, contentType] of modules) {
    const source = path.join(staticRoot, file)
    if (!existsSync(source)) fail(`release does not contain ${file}`)
    assets.set(url, { body: readFileSync(source), contentType })
  }

  return assets
}

function readAssets(vendor, staticAssets) {
  const manifest = JSON.parse(readFileSync(path.join(vendor, 'manifest.json'), 'utf8'))
  const expected = {
    engine: { revision: 'elk-0.11.1', file: 'elk-worker.min.js' },
    worker: { revision: 'worker-v1', file: 'aiur-layout-worker.js' },
    client: { revision: 'client-v1', file: 'aiur-layout-client.js' }
  }

  const assets = new Map(staticAssets)
  for (const [name, spec] of Object.entries(expected)) {
    const asset = manifest.assets?.[name]
    if (!asset || asset.file !== spec.file || !/^[a-f0-9]{64}$/.test(asset.sha256 ?? '')) fail(`${name} has an invalid manifest record`)
    if (asset.url !== `/vendor/layout/${spec.revision}/${asset.sha256}/${spec.file}`) fail(`${name} URL is not content-addressed`)

    const body = readFileSync(path.join(vendor, asset.file))
    if (createHash('sha256').update(body).digest('hex') !== asset.sha256) fail(`${name} bytes do not match the release manifest`)
    assets.set(asset.url, { body, contentType: asset.contentType })
  }

  if (manifest.assets.worker.engineUrl !== manifest.assets.engine.url) fail('worker does not reference the packaged engine URL')

  const sourceAvailability = readFileSync(path.join(vendor, 'SOURCE.md'), 'utf8')
  for (const value of ['EPL-2.0', 'https://github.com/kieler/elkjs', '0.11.1', '572e73323791d05f09b0815ff639af2b67f202ab', 'https://github.com/kieler/elkjs/archive/572e73323791d05f09b0815ff639af2b67f202ab.tar.gz']) {
    if (!sourceAvailability.includes(value)) fail(`packaged source-availability notice is missing ${value}`)
  }

  return { assets, manifest }
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })

  const address = server.address()
  if (!address || typeof address === 'string') fail('could not allocate loopback server')
  return `http://127.0.0.1:${address.port}`
}

const release = releaseArgument(process.argv.slice(2))
const aiurApplication = findAiurApplication(release)
const { assets, manifest } = readAssets(findVendor(aiurApplication), readStaticAssets(aiurApplication))
const workerUrl = manifest.assets.worker.url
const engineUrl = manifest.assets.engine.url
const clientUrl = manifest.assets.client.url

const server = createServer((request, response) => {
  const requestUrl = new URL(request.url ?? '/', 'http://localhost')
  const csp = "default-src 'self'; script-src 'self'; worker-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'"

  if (requestUrl.pathname === '/') {
    response.writeHead(200, { 'content-security-policy': csp, 'content-type': 'text/html; charset=utf-8' })
    response.end(`<!doctype html>
      <meta charset="utf-8">
      <link rel="stylesheet" href="/dashboard.css">
      <section
        id="packaged-layout-root"
        class="bo-layout-root is-layout-fallback"
        data-layout-root-id="packaged-layout-root"
        data-layout-provider-generation="1"
        data-layout-dom-generation="1"
        data-layout-client-url="${clientUrl}"
        data-layout-worker-url="${workerUrl}"
        data-layout-engine-url="${engineUrl}"
        data-layout-adapter-url="/aiur-dom-svg-layout-adapter.js"
        data-layout-health="fallback"
      >
        <div class="bo-layout-cards" data-layout-cards>
          <article class="bo-layout-card" data-layout-node data-layout-node-id="node-0" data-layout-lane="0" data-layout-phase="0"><header data-layout-card-header><h2>First card</h2></header></article>
          <article class="bo-layout-card" data-layout-node data-layout-node-id="node-1" data-layout-lane="1" data-layout-phase="1"><header data-layout-card-header><h2>Second card</h2></header></article>
        </div>
        <svg class="bo-layout-edges" data-layout-edges aria-hidden="true" focusable="false"></svg>
        <section class="bo-layout-dependency-summary"><h2>Dependency summary</h2><ul data-layout-dependency-summary><li data-layout-edge data-layout-edge-id="edge-0" data-layout-edge-source="node-0" data-layout-edge-target="node-1" data-layout-edge-state="blocking">node-0 blocks node-1</li></ul></section>
      </section>
      <script type="module" src="/smoke.mjs"></script>`)
    return
  }

  if (requestUrl.pathname === '/smoke.mjs') {
    response.writeHead(200, { 'content-security-policy': csp, 'content-type': 'application/javascript; charset=utf-8' })
    response.end(`import '/aiur-dom-svg-layout-loader.js';

const root = document.querySelector('#packaged-layout-root');
const context = { el: root };
const hook = window.AiurDomSvgLayout.createLiveViewHook();

function waitForHealth(health) {
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => reject(new Error('layout did not become ' + health)), 5_000);
    const observe = () => {
      if (root.dataset.layoutHealth === health) {
        window.clearTimeout(timeout);
        observer.disconnect();
        resolve();
      }
    };
    const observer = new MutationObserver(observe);
    observer.observe(root, { attributes: true, attributeFilter: ['data-layout-health'] });
    observe();
  });
}

window.runPackagedLayout = async () => {
  hook.mounted.call(context);
  await waitForHealth('ready');
  const svg = root.querySelector('[data-layout-edges]');
  const ready = {
    health: root.dataset.layoutHealth,
    paths: svg.querySelectorAll('path[data-layout-edge-path]').length,
    viewBox: svg.getAttribute('viewBox')
  };

  root.dataset.layoutClientUrl = '';
  hook.beforeUpdate.call(context);
  hook.updated.call(context);
  await waitForHealth('fallback');
  return {
    ready,
    fallback: {
      health: root.dataset.layoutHealth,
      paths: svg.querySelectorAll('path[data-layout-edge-path]').length,
      summary: root.querySelectorAll('[data-layout-dependency-summary] li').length,
      viewBox: svg.getAttribute('viewBox'),
      width: svg.getAttribute('width'),
      height: svg.getAttribute('height')
    }
  };
};`)
    return
  }

  const asset = assets.get(requestUrl.pathname)
  if (!asset) {
    response.writeHead(404, { 'content-security-policy': csp, 'content-type': 'text/plain; charset=utf-8' })
    response.end('Not Found')
    return
  }

  response.writeHead(200, { 'content-security-policy': csp, 'content-type': `${asset.contentType}; charset=utf-8` })
  response.end(asset.body)
})

let browser
try {
  const origin = await listen(server)
  browser = await chromium.launch({ headless: true })
  const context = await browser.newContext()
  const remoteRequests = []

  await context.route('**/*', async (route) => {
    const url = new URL(route.request().url())
    if (url.origin !== origin) {
      remoteRequests.push(url.href)
      await route.abort('blockedbyclient')
      return
    }

    await route.continue()
  })

  const page = await context.newPage()
  const pageErrors = []
  page.on('pageerror', (error) => pageErrors.push(error.message))
  const response = await page.goto(origin, { waitUntil: 'networkidle' })
  if (response?.status() !== 200) fail(`offline smoke index returned ${response?.status() ?? 'no response'}`)

  const result = await page.evaluate(() => window.runPackagedLayout())
  if (result?.ready?.health !== 'ready' || result?.ready?.paths !== 1 || !result?.ready?.viewBox) fail('assembled adapter did not render packaged worker geometry')
  if (result?.fallback?.health !== 'fallback' || result?.fallback?.paths !== 0 || result?.fallback?.summary !== 1) fail('assembled adapter did not preserve semantic fallback')
  if (result?.fallback?.viewBox || result?.fallback?.width || result?.fallback?.height) fail('assembled adapter retained stale SVG dimensions after fallback')
  if (remoteRequests.length > 0) fail(`offline smoke attempted remote URLs: ${remoteRequests.join(', ')}`)
  if (pageErrors.length > 0) fail(`strict-CSP smoke reported page errors: ${pageErrors.join(', ')}`)

  process.stdout.write(`${release}\n`)
} finally {
  await browser?.close()
  await new Promise((resolve) => server.close(resolve))
}
