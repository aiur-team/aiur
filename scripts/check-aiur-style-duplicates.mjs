#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const brand = /#(?:1f57c4|1a4aa8|163e8c|2f86ff|e7d6b2|1a1b1e|16171a|2a2520|edeef0|8c8d93|5f5645)(?![\da-f])|fonts\.googleapis\.com/ig;
const skipped = new Set(['node_modules', 'dist', '.vitepress/cache', '.vitepress/dist', 'aiur-style', 'test-results', 'playwright-report']);

function scan(root) {
  const problems = [];
  function walk(directory, extensions, excluded = skipped) {
    for (const entry of readdirSync(join(root, directory), { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        if (!excluded.has(entry.name) && !excluded.has(relative('website/docs-app', path))) walk(path, extensions, excluded);
      } else if (entry.isFile() && extensions.test(entry.name)) {
        readFileSync(join(root, path), 'utf8').split('\n').forEach((line, index) => {
          // Terminal simulation colours are an independent palette.
          const declarations = line.replace(/--term-[\w-]+\s*:[^;}]+[;}]?/g, '');
          const matches = declarations.match(brand);
          if (matches) problems.push(`${path}:${index + 1}: ${matches.join(', ')}`);
        });
      }
    }
  }
  walk('website', /\.(css|ts|html|vue)$/);
  walk('src/priv/static', /\.css$/, new Set(['aiur-style']));
  walk('src/lib', /\.ex$/);
  return problems;
}

function selfTest() {
  const root = mkdtempSync(join(tmpdir(), 'aiur-style-duplicates-'));
  const script = fileURLToPath(import.meta.url);
  const put = (path, content) => {
    mkdirSync(join(root, path, '..'), { recursive: true });
    writeFileSync(join(root, path), content);
  };
  const check = (status) => {
    const result = spawnSync(process.execPath, [script], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, status, result.stdout + result.stderr);
    return result.stderr;
  };
  try {
    for (const path of ['website/src', 'src/priv/static', 'src/lib']) mkdirSync(join(root, path), { recursive: true });
    check(0);
    put('website/src/duplicate.css', 'color: #1f57c4');
    assert.match(check(1), /website\/src\/duplicate.css:1: #1f57c4/);
    put('website/src/duplicate.css', '--term-blue: #1f57c4;');
    check(0);
    put('website/src/duplicate.css', '--term-blue: #1f57c4; color: #1a4aa8;');
    check(1);
    rmSync(join(root, 'website/src/duplicate.css'));
    for (const path of ['website/src/copy.ts', 'website/copy.html', 'website/docs-app/.vitepress/theme/copy.vue', 'src/priv/static/copy.css', 'src/priv/static/build-home/copy.css', 'src/priv/static/dist/copy.css', 'src/lib/copy.ex']) {
      put(path, '#1F57C4 fonts.googleapis.com');
      assert.match(check(1), /#1F57C4, fonts.googleapis.com/);
      rmSync(join(root, path));
    }
    put('src/priv/static/css/duplicate.css', 'color: #1f57c4');
    assert.match(check(1), /src\/priv\/static\/css\/duplicate.css:1: #1f57c4/);
    rmSync(join(root, 'src/priv/static/css/duplicate.css'));
    for (const path of ['website/public/aiur-style/tokens.css', 'website/node_modules/copy.css', 'website/docs-app/.vitepress/dist/copy.html', 'src/priv/static/aiur-style/tokens.css']) put(path, '#1f57c4');
    check(0);
    console.log('aiur-style duplicate guard self-test passed');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

if (process.argv.includes('--self-test')) selfTest();
else {
  const problems = scan(resolve('.'));
  if (problems.length) {
    console.error(`Use packages/aiur-style instead of duplicating brand values:\n${problems.join('\n')}`);
    process.exitCode = 1;
  } else console.log('aiur-style duplicate guard passed');
}
