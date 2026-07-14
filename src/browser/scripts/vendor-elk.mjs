import { createHash } from 'node:crypto'
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ELK_VERSION = '0.11.1'
const ELK_INTEGRITY = 'sha512-zxxR9k+rx5ktMwT/FwyLdPCrq7xN6e4VGGHH8hA01vVYKjTFik7nHOxBnAYtrgYUB1RpAiLvA1/U2YraWxyKKg=='
const ELK_SOURCE_COMMIT = '572e73323791d05f09b0815ff639af2b67f202ab'
const ELK_SOURCE_ARCHIVE = `https://github.com/kieler/elkjs/archive/${ELK_SOURCE_COMMIT}.tar.gz`
const ENGINE_SIZE_BUDGET = 1_800_000
const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')
const vendorRoot = path.join(sourceRoot, 'priv', 'static', 'vendor', 'elk', ELK_VERSION)
const packageRoot = path.join(browserRoot, 'node_modules', 'elkjs')
const layoutSourceRoot = path.join(browserRoot, 'layout')

const sha256 = (body) => createHash('sha256').update(body).digest('hex')

async function main() {
  const packageJson = JSON.parse(await readFile(path.join(packageRoot, 'package.json'), 'utf8'))
  const lockfile = JSON.parse(await readFile(path.join(browserRoot, 'package-lock.json'), 'utf8'))
  const locked = lockfile.packages?.['node_modules/elkjs']

  if (packageJson.version !== ELK_VERSION || locked?.version !== ELK_VERSION || locked?.integrity !== ELK_INTEGRITY) {
    throw new Error('elkjs package and lockfile do not match the approved 0.11.1 pin')
  }

  const [engine, license, worker, client] = await Promise.all([
    readFile(path.join(packageRoot, 'lib', 'elk-worker.min.js')),
    readFile(path.join(packageRoot, 'LICENSE.md')),
    readFile(path.join(layoutSourceRoot, 'aiur-layout-worker.js')),
    readFile(path.join(layoutSourceRoot, 'aiur-layout-client.js'))
  ])

  if (engine.byteLength > ENGINE_SIZE_BUDGET) throw new Error(`ELK bundle exceeds ${ENGINE_SIZE_BUDGET} byte budget`)

  const assets = {
    engine: assetRecord('elk-0.11.1', 'elk-worker.min.js', engine),
    worker: assetRecord('worker-v1', 'aiur-layout-worker.js', worker),
    client: assetRecord('client-v1', 'aiur-layout-client.js', client)
  }

  const manifest = {
    schema: 1,
    engine: {
      package: 'elkjs',
      version: ELK_VERSION,
      integrity: ELK_INTEGRITY,
      sizeBudgetBytes: ENGINE_SIZE_BUDGET,
      sourceMapPolicy: 'excluded'
    },
    assets: {
      ...assets,
      worker: { ...assets.worker, engineUrl: assets.engine.url }
    }
  }

  await rm(vendorRoot, { recursive: true, force: true })
  await mkdir(vendorRoot, { recursive: true })
  await Promise.all([
    writeFile(path.join(vendorRoot, 'elk-worker.min.js'), engine),
    writeFile(path.join(vendorRoot, 'aiur-layout-worker.js'), worker),
    writeFile(path.join(vendorRoot, 'aiur-layout-client.js'), client),
    writeFile(path.join(vendorRoot, 'LICENSE.md'), license),
    writeFile(path.join(vendorRoot, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`),
    writeFile(path.join(vendorRoot, 'PROVENANCE.md'), provenance(manifest)),
    writeFile(path.join(vendorRoot, 'SOURCE.md'), sourceAvailability(manifest))
  ])
}

function assetRecord(revision, file, body) {
  const hash = sha256(body)

  return {
    file,
    sha256: hash,
    bytes: body.byteLength,
    contentType: 'application/javascript',
    url: `/vendor/layout/${revision}/${hash}/${file}`
  }
}

function provenance(manifest) {
  const { engine, assets } = manifest

  return `# ELK.js provenance\n\n- Package: \`${engine.package}\`\n- Version: \`${engine.version}\`\n- Registry tarball: \`https://registry.npmjs.org/elkjs/-/elkjs-${engine.version}.tgz\`\n- npm integrity: \`${engine.integrity}\`\n- License: \`EPL-2.0\` (full text: \`LICENSE.md\`; source availability: \`SOURCE.md\`)\n- Engine size budget: \`${engine.sizeBudgetBytes}\` bytes\n- Source maps: \`${engine.sourceMapPolicy}\`\n\n## Generated assets\n\n| Asset | SHA-256 | Bytes | Local URL |\n| --- | --- | ---: | --- |\n| engine | \`${assets.engine.sha256}\` | ${assets.engine.bytes} | \`${assets.engine.url}\` |\n| worker | \`${assets.worker.sha256}\` | ${assets.worker.bytes} | \`${assets.worker.url}\` |\n| client | \`${assets.client.sha256}\` | ${assets.client.bytes} | \`${assets.client.url}\` |\n\nRun \`npm run vendor:elk\` from \`src/browser\` after an approved dependency upgrade. Run \`npm run check:elk\` to verify the committed runtime bytes and metadata.\n`
}

function sourceAvailability(manifest) {
  return `# ELK.js source availability\n\nThis product includes the \`${manifest.engine.package}\` ${manifest.engine.version} engine under the Eclipse Public License 2.0 (\`LICENSE.md\`). The corresponding source code is available under the EPL-2.0.\n\n- Upstream repository: \`https://github.com/kieler/elkjs\`\n- Immutable upstream tag: \`0.11.1\`\n- Immutable upstream commit: \`${ELK_SOURCE_COMMIT}\`\n- Source archive: \`${ELK_SOURCE_ARCHIVE}\`\n\nTo obtain the corresponding source, download the archive above or run \`git clone https://github.com/kieler/elkjs.git\`, then \`git checkout ${ELK_SOURCE_COMMIT}\`.\n`
}

await main()
