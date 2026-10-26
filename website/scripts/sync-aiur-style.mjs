import { cp, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = dirname(fileURLToPath(import.meta.resolve('aiur-style/package.json')));
const target = fileURLToPath(new URL('../public/aiur-style/', import.meta.url));
await mkdir(target, { recursive: true });
for (const directory of ['init', 'fonts', 'assets']) {
  await cp(resolve(packageRoot, 'dist', directory), resolve(target, directory), { recursive: true });
}
await cp(resolve(packageRoot, 'dist/fonts.css'), resolve(target, 'fonts.css'));
