import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DuplicateWebhookError,
  InMemoryWebhookIdStore,
  verifyAiurWebhook,
} from '../dist-examples/webhook-receiver.js';

const secret = 'whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=';
const webhookId = 'evt_101';
const timestamp = 1_792_886_400;
const body = '{"contract":"aiur.ticket_lifecycle_event","contract_version":1,"event_id":"evt_101","event_type":"ticket.lifecycle.changed","emitted_at":"2026-10-25T00:00:00Z","ticket_id":"5695","job_id":"run-5695-1","data":{"lifecycle":"running","source":"tracker","observed_at":"2026-10-25T00:00:00Z"}}';
const headers = {
  'webhook-id': webhookId,
  'webhook-timestamp': String(timestamp),
  'webhook-signature': 'v1,x6NtCsb4O8VSnXhPaKG1+9ahN6zNY6uuuZidWBVLbDA=',
};

test('receiver accepts the cross-language signature vector once', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const seen = new InMemoryWebhookIdStore();
  const event = verifyAiurWebhook(body, headers, secret, seen);

  assert.equal(event.event_id, webhookId);
  assert.equal(event.ticket_id, '5695');
  assert.throws(() => verifyAiurWebhook(body, headers, secret, seen), DuplicateWebhookError);
});

test('receiver rejects missing, wrong, stale, future, and body-mismatched deliveries', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const variants = [
    [{ ...headers, 'webhook-signature': undefined }, body],
    [{ ...headers, 'webhook-signature': 'v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' }, body],
    [{ ...headers, 'webhook-timestamp': String(timestamp - 301) }, body],
    [{ ...headers, 'webhook-timestamp': String(timestamp + 301) }, body],
    [headers, body.replace('running', 'paused')],
  ];

  for (const [variantHeaders, variantBody] of variants) {
    assert.throws(() => verifyAiurWebhook(variantBody, variantHeaders, secret, new InMemoryWebhookIdStore()));
  }
});

test('receiver rejects a signed body whose event ID differs from its delivery ID', async (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const { Webhook } = await import('standardwebhooks');
  const mismatched = body.replace(webhookId, 'evt_body_uses_another_id');
  const signature = new Webhook(secret).sign(webhookId, new Date(timestamp * 1_000), mismatched);

  assert.throws(() =>
    verifyAiurWebhook(
      mismatched,
      { ...headers, 'webhook-signature': signature },
      secret,
      new InMemoryWebhookIdStore(),
    ),
  );
});
