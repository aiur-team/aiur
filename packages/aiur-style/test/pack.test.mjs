import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

test('future regression: tarball installs and every exported file resolves from a clean consumer', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'aiur-style-pack-'));
  const run = (command, args, cwd = scratch) => execFileSync(command, args, { cwd, encoding: 'utf8' });
  try {
    // npm 10 can send prepare output before the JSON, even with --ignore-scripts.
    const output = run('npm', ['pack', '--ignore-scripts', '--json', '--pack-destination', scratch], root);
    const [pack] = JSON.parse(output.slice(output.lastIndexOf('\n[') + 1));
    writeFileSync(join(scratch, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
    const source = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', join(scratch, pack.filename), `react@${source.devDependencies.react}`]);
    const installed = join(scratch, 'node_modules/aiur-style');
    const manifest = JSON.parse(readFileSync(join(installed, 'package.json'), 'utf8'));
    assert.equal(manifest.version, source.version);
    assert.deepEqual(manifest.exports, source.exports);
    const exports = [];
    for (const [key, value] of Object.entries(source.exports)) {
      const targets = typeof value === 'string' ? [value] : Object.values(value);
      for (const target of targets) {
        if (target.includes('*')) {
          const prefix = target.slice(0, target.indexOf('*'));
          const files = readdirSync(join(root, prefix), { recursive: true, withFileTypes: true })
            .filter(file => file.isFile());
          assert.ok(files.length, `Empty wildcard export: ${key}`);
          for (const file of files) {
            const parent = file.parentPath ?? file.path;
            const relative = resolve(parent, file.name).slice(resolve(root, prefix).length + 1);
            exports.push([key.replace('*', relative), target.replace('*', relative)]);
          }
        } else {
          exports.push([key, target]);
        }
        assert.ok(pack.files.some(file => file.path === target.replace('./', '') ||
          (target.includes('*') && file.path.startsWith(target.slice(2, target.indexOf('*'))))), `Not packed: ${target}`);
      }
    }
    // CSS, fonts and declarations resolve as files; Node cannot execute those formats.
    // This also guards future export additions without duplicating the manifest.
    writeFileSync(join(scratch, 'check.mjs'), `
      import assert from 'node:assert/strict';
      import { accessSync } from 'node:fs';
      import { fileURLToPath } from 'node:url';
      globalThis.document = { currentScript: { dataset: {} }, documentElement: { removeAttribute() {} } };
      for (const [key, target] of ${JSON.stringify(exports)}) {
        const specifier = key === '.' ? 'aiur-style' : 'aiur-style/' + key.slice(2);
        const url = target.endsWith('.d.ts')
          ? new URL(target, import.meta.resolve('aiur-style/package.json'))
          : import.meta.resolve(specifier);
        accessSync(fileURLToPath(url));
        if (target.endsWith('.js')) await import(specifier);
      }
      console.log('Installed exports checked: ' + ${exports.length});
    `);
    assert.match(run(process.execPath, ['check.mjs']), /Installed exports checked: \d+/);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
