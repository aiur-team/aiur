#!/usr/bin/env node
// The package's own lint: the rules this package must not break.
//
// There is no ESLint here on purpose — the package has no runtime dependencies
// and its checks are about its boundary, not about style preferences: no
// network client, no build step, no per-view colour constants, and a `dist/`
// that matches `src/`.
import { readdir, readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { MODULES } from './modules.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const problems = [];

const files = (await readdir(`${root}src`)).filter((name) => name.endsWith('.js')).sort();
if (files.length === 0) problems.push('src/ has no ES modules');
for (const name of files) {
  if (!MODULES[name]) problems.push(`src/${name} is not listed in scripts/modules.mjs, so nothing imports it`);
}

for (const name of files) {
  const path = `${root}src/${name}`;
  const source = await readFile(path, 'utf8');
  const where = `src/${name}`;

  // Import every module, so a syntax error or a missing export fails here too.
  try {
    if (MODULES[name]) await MODULES[name]();
  } catch (error) {
    problems.push(`${where} does not load: ${error.message}`);
    continue;
  }

  if (/\bconsole\./.test(source)) problems.push(`${where} logs to the console`);
  if (/\bXMLHttpRequest\b|\bnavigator\.sendBeacon\b/.test(source)) problems.push(`${where} reaches the network directly`);
  if (/\brequire\(/.test(source)) problems.push(`${where} uses CommonJS`);
  if (/\t/.test(source)) problems.push(`${where} contains a tab`);
  for (const [index, line] of source.split('\n').entries()) {
    if (line.trimEnd() !== line) problems.push(`${where}:${index + 1} has trailing whitespace`);
  }
}

const styles = await readFile(`${root}src/styles.js`, 'utf8');
if (/#[0-9a-fA-F]{3,8}\b/.test(styles)) problems.push('src/styles.js declares a hex colour instead of an aiur-style token');
if (/\b(rgb|rgba|hsl|hsla)\(/.test(styles)) problems.push('src/styles.js declares a colour function instead of an aiur-style token');

const packageJson = JSON.parse(await readFile(`${root}package.json`, 'utf8'));
for (const dependency of Object.keys(packageJson.dependencies ?? {})) {
  problems.push(`package.json declares a runtime dependency: ${dependency}`);
}
if (!packageJson.peerDependencies?.['aiur-style']) problems.push('package.json must declare aiur-style as a peer dependency');
if (!packageJson.exports?.['./aiur-build-order.css']) problems.push('package.json must export the stylesheet');

// A stale dist/ is how a published tarball ships yesterday's renderer.
if (await exists(`${root}dist/index.js`)) {
  for (const name of files) {
    const source = await readFile(`${root}src/${name}`, 'utf8');
    const built = await readFile(`${root}dist/${name}`, 'utf8').catch(() => null);
    if (built !== source) problems.push(`dist/${name} is stale; run npm run build`);
  }
}

if (problems.length > 0) {
  for (const problem of problems) process.stderr.write(`- ${problem}\n`);
  process.exit(1);
}
process.stdout.write(`lint ok: ${files.length} modules, tokens only, dist current\n`);

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
