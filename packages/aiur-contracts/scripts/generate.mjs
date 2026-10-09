import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { compile } from 'json-schema-to-typescript';

const generated = await compile({
  title: 'WireContract',
  oneOf: [
    { $ref: 'capabilities.v1.schema.json' },
    { $ref: 'capability-error.v1.schema.json' },
  ],
}, 'WireContract', { cwd: fileURLToPath(new URL('../schemas/', import.meta.url)) });
const target = new URL('../src/generated.ts', import.meta.url);
if (process.argv.includes('--check')) {
  if (await readFile(target, 'utf8') !== generated) {
    throw new Error('Generated types are stale; run npm run generate');
  }
} else {
  await writeFile(target, generated);
}
