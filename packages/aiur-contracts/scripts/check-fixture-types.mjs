// Type-checks the golden fixtures against the generated TypeScript types.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const fixture = (name) => readFileSync(join(root, 'fixtures', name), 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'aiur-contracts-'));
const probe = join(dir, 'fixtures.mts');
writeFileSync(probe, [
  `import type { CapabilitiesReport, CapabilityError } from ${JSON.stringify(join(root, 'src/index.js'))};`,
  `export const report: CapabilitiesReport = ${fixture('capabilities.v1.json')};`,
  `export const error: CapabilityError = ${fixture('capability-error.v1.json')};`,
].join('\n'));
const tsc = join(root, 'node_modules/typescript/bin/tsc');
const result = spawnSync(process.execPath, [tsc, '--noEmit', '--strict', '--module', 'NodeNext', '--moduleResolution', 'NodeNext', '--target', 'ES2022', probe], { stdio: 'inherit' });
rmSync(dir, { recursive: true, force: true });
process.exit(result.status ?? 1);
