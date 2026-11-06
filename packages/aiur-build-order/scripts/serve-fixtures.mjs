#!/usr/bin/env node
// Serve the package checkout as a plain page, for the Chromium spec.
//
// Two things are served that a published consumer would get elsewhere: the
// package source itself (no build step needed) and `tokens.css`, generated from
// the @aiur/style token source so the fixture page reads the real `--aiur-*`
// names rather than a hand-copied palette.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const stylePackage = new URL('../../aiur-style/', import.meta.url);
const port = Number(process.env.PORT ?? 4173);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

const tokens = await tokensCss();

createServer(async (request, response) => {
  const path = new URL(request.url ?? '/', `http://127.0.0.1:${port}`).pathname;
  if (path === '/tokens.css') return send(response, 200, 'text/css; charset=utf-8', tokens);

  const file = normalize(join(root, decodeURIComponent(path)));
  if (!file.startsWith(root) || file.includes('/node_modules/')) return send(response, 403, 'text/plain', 'forbidden');

  try {
    const body = await readFile(file);
    return send(response, 200, TYPES[extname(file)] ?? 'application/octet-stream', body);
  } catch {
    return send(response, 404, 'text/plain', `not found: ${path}`);
  }
}).listen(port, '127.0.0.1', () => {
  process.stdout.write(`aiur-build-order fixtures on http://127.0.0.1:${port}/test/browser/fixture-page.html\n`);
});

function send(response, status, type, body) {
  response.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
  response.end(body);
}

/** `@aiur/style` tokens as light-theme custom properties. */
async function tokensCss() {
  const source = await readFile(new URL('src/tokens/tokens.json', stylePackage), 'utf8');
  const tokens = JSON.parse(source);
  const declarations = Object.entries(tokens)
    .map(([name, value]) => `  --aiur-${name.replace(/\./g, '-')}: ${value.light};`)
    .join('\n');
  return `:root {\n${declarations}\n}\n`;
}
