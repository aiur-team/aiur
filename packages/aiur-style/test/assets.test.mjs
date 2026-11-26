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
// Freeze the original imports after AS-50 removes the redundant website files.
test('future regression: original assets retain their imported bytes', () => {
  const originals = {
    'aiur-logo.png': '5f3b8f3dfa3c1376c775ede482bbb2048bbc4a9c51fd4535ba826f0ec7ac7482',
    'favicon.ico': '7e2c794adfa502c40ec7a6a122bf4440d23117d18c579bf891defc5bc3727f01',
    'favicon-16x16.png': 'f1dd7161e923cd8ef3e28f73564e3255add3932756b118eb36bc37a3274cf6d5',
    'favicon-32x32.png': '7eeb7e8034e0613e2984d97bb8b61bd18497e915542359767862e4b6214e5daa',
    'apple-touch-icon.png': '69803b1146c7f6ea7a242eb6aae14a9951d058ea4aaf7fcac6fbe0cd54c33ca9',
    'android-chrome-192x192.png': '8de87db505c633edc9b53f473b37c68ad3bf2fe2c681dda1131a9b4d9408fa51',
    'android-chrome-512x512.png': 'cad46f19aafd763d90d04141c9c75acfbe0005e8f3d6232f1d7625c3196c6de4',
    'site.webmanifest': 'c43bd1fc2f36b6d5fba728c62c5e2f130bb022dba187b55093e0c175432bad09',
  };
  for (const [file, hash] of Object.entries(originals)) assert.equal(sha(`assets/${file}`), hash, file);
});
