import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

function fail(message) {
  process.stderr.write(`check-layout-assets-release: ${message}\n`)
  process.exit(1)
}

function releaseArgument(argv) {
  if (argv.length !== 2 || argv[0] !== '--release') fail('usage: --release <dir>')
  return path.resolve(argv[1])
}

const release = releaseArgument(process.argv.slice(2))
const applications = path.join(release, 'lib')

if (!existsSync(applications)) fail(`release lib directory is missing: ${applications}`)

const aiurApp = readdirSync(applications).find((entry) => entry.startsWith('aiur-'))
if (!aiurApp) fail('release does not contain an aiur application directory')

const vendor = path.join(applications, aiurApp, 'priv', 'static', 'vendor', 'elk', '0.11.1')
const manifestPath = path.join(vendor, 'manifest.json')
const expectedAssets = {
  engine: { revision: 'elk-0.11.1', file: 'elk-worker.min.js' },
  worker: { revision: 'worker-v1', file: 'aiur-layout-worker.js' },
  client: { revision: 'client-v1', file: 'aiur-layout-client.js' }
}

if (!existsSync(manifestPath)) fail('release does not contain the ELK manifest')

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
if (manifest.engine?.package !== 'elkjs' || manifest.engine?.version !== '0.11.1' || manifest.engine?.integrity !== 'sha512-zxxR9k+rx5ktMwT/FwyLdPCrq7xN6e4VGGHH8hA01vVYKjTFik7nHOxBnAYtrgYUB1RpAiLvA1/U2YraWxyKKg==') fail('release manifest does not carry the approved ELK pin')
if (manifest.engine?.sourceMapPolicy !== 'excluded') fail('release manifest allows source maps')

for (const [name, expected] of Object.entries(expectedAssets)) {
  const asset = manifest.assets?.[name]
  if (asset?.file !== expected.file || !/^[a-f0-9]{64}$/.test(asset?.sha256 ?? '') || asset?.contentType !== 'application/javascript') fail(`${name} has an invalid local asset record`)
  if (asset.url !== `/vendor/layout/${expected.revision}/${asset.sha256}/${expected.file}`) fail(`${name} URL is not content-addressed`)
  const assetPath = path.join(vendor, asset.file)

  if (!existsSync(assetPath)) fail(`release is missing ${name} asset ${asset.file}`)
  if (sha256(readFileSync(assetPath)) !== asset.sha256) fail(`release ${name} asset does not match its recorded SHA-256`)
  if (readFileSync(assetPath).byteLength !== asset.bytes) fail(`release ${name} asset does not match its recorded byte size`)
}

for (const file of ['LICENSE.md', 'PROVENANCE.md', 'SOURCE.md']) {
  if (!existsSync(path.join(vendor, file))) fail(`release is missing ${file}`)
}

const sourceAvailability = readFileSync(path.join(vendor, 'SOURCE.md'), 'utf8')
for (const value of ['EPL-2.0', 'https://github.com/kieler/elkjs', '0.11.1', '572e73323791d05f09b0815ff639af2b67f202ab', 'https://github.com/kieler/elkjs/archive/572e73323791d05f09b0815ff639af2b67f202ab.tar.gz']) {
  if (!sourceAvailability.includes(value)) fail(`release source-availability notice is missing ${value}`)
}

if (readdirSync(vendor).some((file) => file.endsWith('.map'))) fail('release vendor directory contains a source map')

process.stdout.write(`${vendor}\n`)

function sha256(body) {
  return createHash('sha256').update(body).digest('hex')
}
