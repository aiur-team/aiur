import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { cp, mkdir, mkdtemp, readdir, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const ELK_VERSION = '0.11.1'
const ELK_INTEGRITY = 'sha512-zxxR9k+rx5ktMwT/FwyLdPCrq7xN6e4VGGHH8hA01vVYKjTFik7nHOxBnAYtrgYUB1RpAiLvA1/U2YraWxyKKg=='
const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')
const vendorRoot = path.join(sourceRoot, 'priv', 'static', 'vendor', 'elk', ELK_VERSION)
const packageRoot = path.join(browserRoot, 'node_modules', 'elkjs')
const layoutSourceRoot = path.join(browserRoot, 'layout')
const repositoryRoot = path.resolve(sourceRoot, '..')
const execFileAsync = promisify(execFile)
const lineEndingPaths = [
  'src/browser/layout/aiur-layout-worker.js',
  'src/browser/layout/aiur-layout-client.js',
  'src/priv/static/vendor/elk/0.11.1/elk-worker.min.js',
  'src/priv/static/vendor/elk/0.11.1/aiur-layout-worker.js',
  'src/priv/static/vendor/elk/0.11.1/aiur-layout-client.js',
  'src/priv/static/vendor/elk/0.11.1/LICENSE.md',
  'src/priv/static/vendor/elk/0.11.1/manifest.json',
  'src/priv/static/vendor/elk/0.11.1/PROVENANCE.md'
]

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
  await verifyLineEndingContract([sourceWorker, sourceClient, engine, license, worker, client, Buffer.from(manifestText), Buffer.from(provenance)])

  for (const value of [manifest.engine.integrity, manifest.assets.engine.sha256, manifest.assets.worker.sha256, manifest.assets.client.sha256]) {
    assert(provenance.includes(value), 'provenance must record every integrity value')
  }
}

async function verifyLineEndingContract(javascriptAssets) {
  const attributes = await readFile(path.join(repositoryRoot, '.gitattributes'), 'utf8')
  const requiredRules = [
    'src/browser/layout/aiur-layout-worker.js text eol=lf',
    'src/browser/layout/aiur-layout-client.js text eol=lf',
    'src/priv/static/vendor/elk/0.11.1/elk-worker.min.js -text',
    'src/priv/static/vendor/elk/0.11.1/aiur-layout-worker.js text eol=lf',
    'src/priv/static/vendor/elk/0.11.1/aiur-layout-client.js text eol=lf',
    'src/priv/static/vendor/elk/0.11.1/LICENSE.md -text',
    'src/priv/static/vendor/elk/0.11.1/manifest.json text eol=lf',
    'src/priv/static/vendor/elk/0.11.1/PROVENANCE.md text eol=lf'
  ]

  for (const rule of requiredRules) assert(attributes.includes(rule), `missing EOL preservation rule: ${rule}`)
  for (const body of javascriptAssets) assert(!body.includes(0x0d), 'autocrlf checkout changed an audited JavaScript asset')
  await verifyAutocrlfCheckout()
}

async function verifyAutocrlfCheckout() {
  const checkout = await mkdtemp(path.join(tmpdir(), 'aiur-layout-eol-'))

  try {
    await Promise.all([
      cp(path.join(repositoryRoot, '.gitattributes'), path.join(checkout, '.gitattributes')),
      ...lineEndingPaths.map(async (relativePath) => {
        const destination = path.join(checkout, relativePath)
        await mkdir(path.dirname(destination), { recursive: true })
        await cp(path.join(repositoryRoot, relativePath), destination)
      })
    ])
    await execFileAsync('git', ['init', '--quiet'], { cwd: checkout })
    await execFileAsync('git', ['add', '.'], { cwd: checkout })
    await execFileAsync('git', ['-c', 'user.name=Layout EOL Check', '-c', 'user.email=layout-eol@example.invalid', 'commit', '--quiet', '-m', 'Preserve layout bytes'], { cwd: checkout })
    await execFileAsync('git', ['config', 'core.autocrlf', 'true'], { cwd: checkout })
    await execFileAsync('git', ['checkout', '--force', 'HEAD'], { cwd: checkout })

    for (const relativePath of lineEndingPaths) {
      const body = await readFile(path.join(checkout, relativePath))
      assert(!body.includes(0x0d), `autocrlf checkout changed ${relativePath}`)
    }
  } finally {
    await rm(checkout, { recursive: true, force: true })
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
