import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const root = new URL('../', import.meta.url);
const sha = file => createHash('sha256').update(readFileSync(new URL(file, root))).digest('hex');
const hashes = {
  'Bungee-Regular.woff2': '4513a7d68c82c053f363075a8aee249d60146f7c0bb7236cd27d721bffd16eeb',
  'SpaceGrotesk-Variable.woff2': 'cb48953e20ccd61690a20f1d910d333aa3a352e62ac18d3ffc4e0264a3c4aaa4',
  'JetBrainsMono-Variable.woff2': '11038e282dd7cb983dfc4e565017f37a91041c073c8929771fb6e64d27814396',
};
for (const [file, hash] of Object.entries(hashes)) {
  test(`${file} matches pinned Khala source and shipped copy`, () => {
    assert.equal(sha(`fonts/${file}`), hash);
    assert.equal(sha(`dist/fonts/${file}`), hash);
    assert.ok(readFileSync(new URL('assets/SOURCES.md', root), 'utf8').includes(hash));
  });
}
test('build ships every asset and license byte for byte', () => {
  const output = mkdtempSync(join(tmpdir(), 'as12-dist-'));
  try {
    execFileSync(process.execPath, ['scripts/build.mjs', output], { cwd: root, stdio: 'pipe' });
    for (const directory of ['assets', 'fonts']) {
      for (const file of readdirSync(new URL(`${directory}/`, root))) {
        assert.deepEqual(readFileSync(join(output, directory, file)), readFileSync(new URL(`${directory}/${file}`, root)));
      }
    }
  } finally {
    rmSync(output, { recursive: true, force: true });
  }
});
test('optimized logo size budgets', () => {
  for (const [ext, limit] of [['png', 160000], ['webp', 90000]]) {
    assert.ok(statSync(new URL(`dist/assets/aiur-logo-512.${ext}`, root)).size <= limit);
  }
});
test('original logo and favicons match website sources', () => {
  for (const file of ['aiur-logo.png', 'favicon.ico', 'favicon-16x16.png', 'favicon-32x32.png',
    'apple-touch-icon.png', 'android-chrome-192x192.png', 'android-chrome-512x512.png', 'site.webmanifest']) {
    const source = file === 'aiur-logo.png' ? `assets/${file}` : file;
    const website = readFileSync(new URL(`../../website/public/${source}`, root));
    assert.deepEqual(readFileSync(new URL(`assets/${file}`, root)), website);
  }
});
