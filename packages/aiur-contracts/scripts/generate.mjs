import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { compile } from 'json-schema-to-typescript';

const cwd = fileURLToPath(new URL('../schemas/', import.meta.url));
const outputs = [
  {
    name: 'WireContract',
    target: new URL('../src/generated.ts', import.meta.url),
    refs: ['capabilities.v1.schema.json', 'capability-error.v1.schema.json'],
  },
  {
    name: 'StatusContract',
    target: new URL('../src/status.generated.ts', import.meta.url),
    refs: [
      'agents.v1.schema.json',
      'status.v1.schema.json',
      'ticket.v1.schema.json',
      'ticket-cancel.v1.schema.json',
      'ticket-usage.v1.schema.json',
      'ticket-progress.v1.schema.json',
    ],
  },
  {
    name: 'TicketSpendCapContract',
    target: new URL('../src/spend-cap.generated.ts', import.meta.url),
    refs: [
      'ticket-spend-cap.v1.schema.json',
      'ticket-spend-cap-reached.v1.schema.json',
    ],
  },
  {
    name: 'VoiceConverseContract',
    target: new URL('../src/voice-converse.generated.ts', import.meta.url),
    refs: ['voice-converse.v1.schema.json'],
  },
];

for (const output of outputs) {
  const generated = await compile({
    title: output.name,
    oneOf: output.refs.map(($ref) => ({ $ref })),
  }, output.name, { cwd });

  if (process.argv.includes('--check')) {
    if (await readFile(output.target, 'utf8') !== generated) {
      throw new Error('Generated types are stale; run npm run generate');
    }
  } else {
    await writeFile(output.target, generated);
  }
}
