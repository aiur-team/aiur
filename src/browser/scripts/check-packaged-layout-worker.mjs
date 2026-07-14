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

function findVendor(release) {
  const applications = path.join(release, 'lib')
  if (!existsSync(applications)) fail(`release lib directory is missing: ${applications}`)

  const aiurApplication = readdirSync(applications).find((entry) => entry.startsWith('aiur-'))
  if (!aiurApplication) fail('release does not contain an aiur application directory')

  const vendor = path.join(applications, aiurApplication, 'priv', 'static', 'vendor', 'elk', '0.11.1')
  if (!existsSync(vendor)) fail('release does not contain the ELK vendor directory')
  return vendor
}

function readAssets(vendor) {
  const manifest = JSON.parse(readFileSync(path.join(vendor, 'manifest.json'), 'utf8'))
  const expected = {
    engine: { revision: 'elk-0.11.1', file: 'elk-worker.min.js' },
    worker: { revision: 'worker-v1', file: 'aiur-layout-worker.js' },
    client: { revision: 'client-v1', file: 'aiur-layout-client.js' }
  }

  const assets = new Map()
  for (const [name, spec] of Object.entries(expected)) {
    const asset = manifest.assets?.[name]
    if (!asset || asset.file !== spec.file || !/^[a-f0-9]{64}$/.test(asset.sha256 ?? '')) fail(`${name} has an invalid manifest record`)
    if (asset.url !== `/vendor/layout/${spec.revision}/${asset.sha256}/${spec.file}`) fail(`${name} URL is not content-addressed`)

    const body = readFileSync(path.join(vendor, asset.file))
    if (createHash('sha256').update(body).digest('hex') !== asset.sha256) fail(`${name} bytes do not match the release manifest`)
    assets.set(asset.url, { body, contentType: asset.contentType })
  }

  if (manifest.assets.worker.engineUrl !== manifest.assets.engine.url) fail('worker does not reference the packaged engine URL')
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
const { assets, manifest } = readAssets(findVendor(release))
const workerUrl = manifest.assets.worker.url
const engineUrl = manifest.assets.engine.url
const clientUrl = manifest.assets.client.url

const server = createServer((request, response) => {
  const requestUrl = new URL(request.url ?? '/', 'http://localhost')
  const csp = "default-src 'self'; script-src 'self'; worker-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'"

  if (requestUrl.pathname === '/') {
    response.writeHead(200, { 'content-security-policy': csp, 'content-type': 'text/html; charset=utf-8' })
    response.end('<!doctype html><meta charset="utf-8"><script type="module" src="/smoke.mjs"></script>')
    return
  }

  if (requestUrl.pathname === '/smoke.mjs') {
    response.writeHead(200, { 'content-security-policy': csp, 'content-type': 'application/javascript; charset=utf-8' })
    response.end(`import { createLayoutWorkerClient } from ${JSON.stringify(clientUrl)};
window.runPackagedLayout = async () => {
  const client = createLayoutWorkerClient({ workerUrl: ${JSON.stringify(workerUrl)}, engineUrl: ${JSON.stringify(engineUrl)} });
  const response = await client.layout({
    type: 'layout', version: 1, requestId: 'request_1_2', generation: 1,
    nodes: [
      { id: 'node_0', width: 120, height: 48, lane: 0, phase: 0 },
      { id: 'node_1', width: 120, height: 48, lane: 1, phase: 1 }
    ],
    edges: [{ id: 'edge_0', source: 'node_0', target: 'node_1' }],
    constraints: { lanes: [{ index: 0 }, { index: 1 }], phases: [{ index: 0 }, { index: 1 }] },
    options: { direction: 'RIGHT', edgeRouting: 'ORTHOGONAL', randomSeed: 1, thoroughness: 1 }
  });
  client.dispose();
  return response;
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
  const response = await page.goto(origin, { waitUntil: 'networkidle' })
  if (response?.status() !== 200) fail(`offline smoke index returned ${response?.status() ?? 'no response'}`)

  const result = await page.evaluate(() => window.runPackagedLayout())
  if (result?.type !== 'result' || result?.nodes?.length !== 2 || result?.edges?.length !== 1) fail('packaged worker did not return bounded geometry')
  if (remoteRequests.length > 0) fail(`offline smoke attempted remote URLs: ${remoteRequests.join(', ')}`)

  process.stdout.write(`${release}\n`)
} finally {
  await browser?.close()
  await new Promise((resolve) => server.close(resolve))
}
