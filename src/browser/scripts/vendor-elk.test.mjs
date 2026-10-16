import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const vendorRelative = 'priv/static/vendor/elk/0.11.1'

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'aiur-3417-vendor-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const relative of ['scripts', 'layout', 'package-lock.json', 'node_modules/elkjs']) {
    await cp(path.join(browserRoot, relative), path.join(root, 'browser', relative), { recursive: true })
  }
  await cp(path.resolve(browserRoot, '..', vendorRelative), path.join(root, vendorRelative), { recursive: true })
  const vendor = path.join(root, vendorRelative)
  const manifest = JSON.parse(await readFile(path.join(vendor, 'manifest.json'), 'utf8'))
  return { root, vendor, manifest, run: () => spawnSync(process.execPath, [path.join(root, 'browser/scripts/vendor-elk.mjs'), '--check'], { encoding: 'utf8' }) }
}

test('check mode rebuilds missing assets with pinned bytes and logs the engine digest', async (t) => {
  const f = await fixture(t)
  for (const asset of Object.values(f.manifest.assets)) await rm(path.join(f.vendor, asset.file), { force: true })
  const result = f.run()
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, new RegExp(`sha256=${f.manifest.assets.engine.sha256}`))
  for (const asset of Object.values(f.manifest.assets)) {
    const body = await readFile(path.join(f.vendor, asset.file))
    const { createHash } = await import('node:crypto')
    assert.equal(createHash('sha256').update(body).digest('hex'), asset.sha256)
  }
})

test('check mode rejects changed worker parts without overwriting stale assets or the manifest', async (t) => {
  const f = await fixture(t)
  const manifestBefore = await readFile(path.join(f.vendor, 'manifest.json'))
  const workerPath = path.join(f.vendor, 'aiur-layout-worker.js')
  await writeFile(workerPath, 'stale worker')
  await writeFile(path.join(f.root, 'browser/layout/worker/40-extra.js'), '\n// unapproved change\n')
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /differ from the tracked manifest/)
  assert.equal(await readFile(workerPath, 'utf8'), 'stale worker')
  assert.deepEqual(await readFile(path.join(f.vendor, 'manifest.json')), manifestBefore)
})

// Existing pin guard retained against future regression; not coverage of the build-output change.
test('lockfile drift fails before generating any missing output', async (t) => {
  const f = await fixture(t)
  const lock = path.join(f.root, 'browser/package-lock.json')
  const contents = JSON.parse(await readFile(lock, 'utf8'))
  contents.packages['node_modules/elkjs'].integrity = 'unapproved'
  await writeFile(lock, JSON.stringify(contents))
  const engine = path.join(f.vendor, 'elk-worker.min.js')
  await rm(engine, { force: true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /do not match the approved 0.11.1 pin/)
  await assert.rejects(readFile(engine), { code: 'ENOENT' })
})
