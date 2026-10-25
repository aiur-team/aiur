import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const consumer = mkdtempSync(join(tmpdir(), 'aiur-contracts-consumer-'));

try {
  const pack = run('npm', ['pack', '--json', '--pack-destination', consumer], root);
  const [{ filename }] = JSON.parse(pack.stdout);
  writeFileSync(join(consumer, 'package.json'), JSON.stringify({ name: 'aiur-contracts-consumer', private: true, type: 'module' }));
  run('npm', ['install', '--ignore-scripts', join(consumer, filename)], consumer);

  writeFileSync(join(consumer, 'probe.mts'), `
    import type { OutboundEvent, TicketLifecycleChangedEvent } from '@aiur/contracts';
    import lifecycleSchema from '@aiur/contracts/schemas/ticket-lifecycle-event.v1.schema.json' with { type: 'json' };
    const event: TicketLifecycleChangedEvent = {
      contract: 'aiur.ticket_lifecycle_event',
      contract_version: 1,
      event_id: 'evt_pack_check',
      event_type: 'ticket.lifecycle.changed',
      emitted_at: '2026-10-25T00:00:00Z',
      ticket_id: '5695',
      data: { lifecycle: 'running', source: 'tracker', observed_at: '2026-10-25T00:00:00Z' },
    };
    export const pair: [OutboundEvent, string] = [event, lifecycleSchema.$id];
  `);

  const tsc = join(root, 'node_modules', 'typescript', 'bin', 'tsc');
  run(process.execPath, [tsc, '--noEmit', '--strict', '--resolveJsonModule', '--module', 'NodeNext', '--moduleResolution', 'NodeNext', '--target', 'ES2022', join(consumer, 'probe.mts')], consumer);
  run(process.execPath, ['--input-type=module', '--eval', `
    import { KNOWN_CAPABILITY_IDS } from '@aiur/contracts';
    import { InMemoryWebhookIdStore } from '@aiur/contracts/webhook-receiver';
    import schema from '@aiur/contracts/schemas/ticket-lifecycle-event.v1.schema.json' with { type: 'json' };
    if (!KNOWN_CAPABILITY_IDS.includes('events.export') || schema.$id.length === 0 || !new InMemoryWebhookIdStore()) process.exit(1);
  `], consumer);
} finally {
  rmSync(consumer, { recursive: true, force: true });
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.status !== 0) {
    process.stderr.write(result.stdout);
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  return result;
}
