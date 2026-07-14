import { createHash } from 'node:crypto'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ELK_VERSION = '0.11.1'
const ELK_INTEGRITY = 'sha512-zxxR9k+rx5ktMwT/FwyLdPCrq7xN6e4VGGHH8hA01vVYKjTFik7nHOxBnAYtrgYUB1RpAiLvA1/U2YraWxyKKg=='
const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')
const vendorRoot = path.join(sourceRoot, 'priv', 'static', 'vendor', 'elk', ELK_VERSION)
const packageRoot = path.join(browserRoot, 'node_modules', 'elkjs')
const layoutSourceRoot = path.join(browserRoot, 'layout')

const sha256 = (body) => createHash('sha256').update(body).digest('hex')

async function main() {
  const [manifestText, provenance, lockfileText, generatedFiles] = await Promise.all([
    readFile(path.join(vendorRoot, 'manifest.json'), 'utf8'),
    readFile(path.join(vendorRoot, 'PROVENANCE.md'), 'utf8'),
    readFile(path.join(browserRoot, 'package-lock.json'), 'utf8'),
    readdir(vendorRoot)
  ])
  const manifest = JSON.parse(manifestText)
  const lockfile = JSON.parse(lockfileText)
  const locked = lockfile.packages?.['node_modules/elkjs']

  assert(manifest.schema === 1, 'manifest schema must be 1')
  assert(manifest.engine?.package === 'elkjs', 'manifest package must be elkjs')
  assert(manifest.engine?.version === ELK_VERSION, 'manifest version must be 0.11.1')
  assert(manifest.engine?.integrity === ELK_INTEGRITY, 'manifest integrity must match the approved pin')
  assert(manifest.engine?.sourceMapPolicy === 'excluded', 'manifest must exclude source maps')
  assert(locked?.version === ELK_VERSION && locked?.integrity === ELK_INTEGRITY, 'lockfile must match approved elkjs pin')
  assert(!generatedFiles.some((file) => file.endsWith('.map')), 'vendor tree must not contain source maps')

  const [sourceEngine, sourceLicense, sourceWorker, sourceClient] = await Promise.all([
    readFile(path.join(packageRoot, 'lib', 'elk-worker.min.js')),
    readFile(path.join(packageRoot, 'LICENSE.md')),
    readFile(path.join(layoutSourceRoot, 'aiur-layout-worker.js')),
    readFile(path.join(layoutSourceRoot, 'aiur-layout-client.js'))
  ])
  const [engine, license, worker, client] = await Promise.all([
    readFile(path.join(vendorRoot, 'elk-worker.min.js')),
    readFile(path.join(vendorRoot, 'LICENSE.md')),
    readFile(path.join(vendorRoot, 'aiur-layout-worker.js')),
    readFile(path.join(vendorRoot, 'aiur-layout-client.js'))
  ])

  assert(sourceEngine.equals(engine), 'committed engine bytes must match locked elkjs bundle')
  assert(sourceLicense.equals(license), 'committed license must match locked elkjs package')
  assert(sourceWorker.equals(worker), 'committed worker bytes must match authored source')
  assert(sourceClient.equals(client), 'committed client bytes must match authored source')
  assert(engine.byteLength <= manifest.engine.sizeBudgetBytes, 'engine exceeds committed size budget')

  verifyAsset(manifest.assets?.engine, engine, 'elk-0.11.1', 'elk-worker.min.js')
  verifyAsset(manifest.assets?.worker, worker, 'worker-v1', 'aiur-layout-worker.js')
  verifyAsset(manifest.assets?.client, client, 'client-v1', 'aiur-layout-client.js')
  assert(manifest.assets.worker.engineUrl === manifest.assets.engine.url, 'worker must import the manifest engine URL')

  for (const value of [manifest.engine.integrity, manifest.assets.engine.sha256, manifest.assets.worker.sha256, manifest.assets.client.sha256]) {
    assert(provenance.includes(value), 'provenance must record every integrity value')
  }
}

function verifyAsset(asset, body, revision, file) {
  assert(asset?.file === file, `${file} record is missing`)
  assert(asset.sha256 === sha256(body), `${file} hash does not match committed bytes`)
  assert(asset.bytes === body.byteLength, `${file} size does not match committed bytes`)
  assert(asset.contentType === 'application/javascript', `${file} content type is invalid`)
  assert(asset.url === `/vendor/layout/${revision}/${asset.sha256}/${file}`, `${file} URL is not content-addressed`)
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

await main()
