import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { componentCssFiles, isBundled, readableCss } from '../scripts/build.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));

test('future regression: bundle includes every readable component and matches a fresh build', () => {
  const output = fs.mkdtempSync(path.join(os.tmpdir(), 'footer-bundle-'));
  try {
    execFileSync(process.execPath, [path.join(root, 'scripts/build.mjs'), output]);
    const bundle = fs.readFileSync(path.join(output, 'aiur-style.css'), 'utf8');
    assert.equal(bundle, fs.readFileSync(path.join(root, 'dist/aiur-style.css'), 'utf8'));
    const files = componentCssFiles();
    assert.deepEqual(fs.readdirSync(path.join(output, 'css')).sort(), files, 'every emitted css/ file is checked below');
    for (const file of fs.readdirSync(path.join(root, 'src/css'))) {
      assert.ok(files.includes(file) || fs.existsSync(path.join(output, file)), `${file} must be emitted by the build`);
    }
    for (const file of files) {
      const source = fs.readFileSync(path.join(root, 'src/css', file), 'utf8');
      assert.equal(fs.readFileSync(path.join(output, 'css', file), 'utf8'), readableCss(source), `${file} stays readable`);
      if (!isBundled(file)) continue;
      const rules = source.replace(/\s+/g, ' ').trim();
      assert.ok(bundle.replace(/\s+/g, ' ').includes(rules), `${file} rules must appear in the bundle`);
    }
  } finally {
    fs.rmSync(output, { recursive: true, force: true });
  }
});

test('future regression: bundle preserves CSS strings, escapes and required token spacing', () => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'footer-css-'));
  try {
    fs.cpSync(root, fixture, { recursive: true, filter: source => !['node_modules', 'dist', 'test-results', 'test'].includes(path.relative(root, source).split(path.sep)[0]) });
    fs.symlinkSync(path.join(root, 'node_modules'), path.join(fixture, 'node_modules'), 'dir');
    const css = `.aiur-fixture span { content: "two  spaces /* literal */ \\"quote\\""; width: calc(100% - 2px); }\n/* discard this */\n`;
    fs.writeFileSync(path.join(fixture, 'src/css/fixture.css'), css);
    execFileSync(process.execPath, [path.join(fixture, 'scripts/build.mjs')]);
    const bundle = fs.readFileSync(path.join(fixture, 'dist/aiur-style.css'), 'utf8');
    assert.ok(bundle.includes('.aiur-fixture span { content: "two  spaces /* literal */ \\"quote\\""; width: calc(100% - 2px); }'));
    assert.equal(fs.readFileSync(path.join(fixture, 'dist/css/fixture.css'), 'utf8'), css);
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }
});
