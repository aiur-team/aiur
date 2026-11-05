#!/usr/bin/env node
/**
 * A minimal embedding host for Aiur Commands.
 *
 * It demonstrates the whole boundary and nothing more:
 *
 *   - the host's *server* holds the Aiur instance credential
 *     (`AIUR_SUPERVISOR_TOKEN`) and exchanges it for a short-lived,
 *     ticket-scoped grant;
 *   - the browser receives only that grant, never the instance credential;
 *   - reads go to `/api/v1/commands` with the grant, and the page renders the
 *     `@aiur/commands` component from the response.
 *
 * Run it:
 *
 *   AIUR_BASE_URL=http://127.0.0.1:4000 \
 *   AIUR_SUPERVISOR_TOKEN=... \
 *   AIUR_HOST_TICKETS=42,43 \
 *   AIUR_HOST_PRINCIPAL=player-7 \
 *   node examples/host.mjs
 *
 * Then open http://127.0.0.1:8787/ .
 *
 * `node examples/host.mjs --self-check` renders a fixed Command component and
 * exits, without touching the network.
 */

import { createServer } from 'node:http';
import { renderList } from '../src/render.mjs';

const DEFAULT_PORT = 8787;
const SCOPE_TTL_SECONDS = 300;

function config(env = process.env) {
  return {
    baseUrl: env.AIUR_BASE_URL ?? 'http://127.0.0.1:4000',
    supervisorToken: env.AIUR_SUPERVISOR_TOKEN ?? '',
    tickets: (env.AIUR_HOST_TICKETS ?? '').split(',').map((ticket) => ticket.trim()).filter(Boolean),
    principal: env.AIUR_HOST_PRINCIPAL ?? 'example-user',
    port: Number(env.AIUR_HOST_PORT ?? DEFAULT_PORT),
  };
}

/** Exchanges the host's instance credential for a ticket-scoped grant. */
export async function mintScope({ baseUrl, supervisorToken, principal, tickets, expiresIn = SCOPE_TTL_SECONDS }) {
  const response = await fetch(new URL('/api/v1/commands/scope', baseUrl), {
    method: 'POST',
    headers: {
      authorization: `Bearer ${supervisorToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ principal, tickets, expires_in: expiresIn }),
  });

  if (!response.ok) {
    throw new Error(`scope mint failed: ${response.status} ${await response.text()}`);
  }

  return response.json();
}

/** Reads the Commands the grant may see. */
export async function listCommands({ baseUrl, token, query = {} }) {
  const url = new URL('/api/v1/commands', baseUrl);

  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
  }

  const response = await fetch(url, { headers: { authorization: `Bearer ${token}` } });

  if (!response.ok) {
    throw new Error(`command list failed: ${response.status} ${await response.text()}`);
  }

  return response.json();
}

function page(config, list) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Aiur Commands for ${config.principal}</title>
    <style>
      body { font: 15px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 46rem; }
      .aiur-command { border: 1px solid #d7dbe0; border-radius: 12px; padding: 1rem; margin-bottom: 1rem; }
      .aiur-command-state { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #58606a; }
      .aiur-command-chip { font-size: 11px; border: 1px solid currentColor; border-radius: 999px; padding: 0 6px; }
      .aiur-command-option { display: flex; gap: .5rem; align-items: flex-start; padding: .35rem 0; }
      .aiur-commands[data-command-list-state="empty"] { color: #58606a; }
    </style>
  </head>
  <body>
    <h1>Commands for ${config.principal}</h1>
    <p>Ticket scope: ${config.tickets.join(', ')}</p>
    ${renderList(list, { answerUrl: '/api/commands/answer' })}
  </body>
</html>`;
}

/** Starts the example host server. */
export function startHost(config) {
  return createServer(async (request, response) => {
    try {
      if (request.url === '/' || request.url?.startsWith('/?')) {
        const { token } = await mintScope(config);
        const list = await listCommands({ baseUrl: config.baseUrl, token });

        response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        response.end(page(config, list));
        return;
      }

      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('not found');
    } catch (error) {
      response.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      response.end(`upstream error: ${error.message}`);
    }
  });
}

function selfCheck() {
  const list = {
    status: 'ready',
    count: 1,
    error: null,
    commands: [
      {
        state: 'pending',
        decision_id: 'dec_self',
        question: 'Ship the build?',
        ticket: { identifier: '42', title: 'Game', url: null },
        blocking: true,
        options: [{ id: 'approve', label: 'Approve' }],
        recommendation: { option_id: 'approve', label: 'Approve' },
        free_response: { allowed: true, required: false },
        answer: null,
        conflict: null,
        media: [],
        actions: { answer: true, revise: false, enrich: false },
      },
    ],
  };

  const html = renderList(list);

  if (!html.includes('data-command-state="pending"') || !html.includes('data-command-list-state="ready"')) {
    throw new Error('self-check failed: component did not render the pending state');
  }

  console.log('aiur-commands example self-check OK');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv.includes('--self-check')) {
    selfCheck();
  } else {
    const settings = config();

    if (!settings.supervisorToken || settings.tickets.length === 0) {
      console.error('Set AIUR_SUPERVISOR_TOKEN and AIUR_HOST_TICKETS before running the example host.');
      process.exit(1);
    }

    startHost(settings).listen(settings.port, '127.0.0.1', () => {
      console.log(`example host on http://127.0.0.1:${settings.port}/ for tickets ${settings.tickets.join(', ')}`);
    });
  }
}
