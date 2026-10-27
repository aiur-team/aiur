import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { Webhook } from 'standardwebhooks';
import {
  DuplicateWebhookError,
  InMemoryWebhookIdStore,
  verifyAiurWebhook,
} from '../dist-examples/webhook-receiver.js';

const vector = JSON.parse(
  readFileSync(new URL('../fixtures/webhook-signature-vector.v1.json', import.meta.url), 'utf8'),
);
const { secret, msg_id: webhookId, timestamp, body, signature } = vector;
const headers = {
  'webhook-id': webhookId,
  'webhook-timestamp': String(timestamp),
  'webhook-signature': signature,
};

test('pinned verifier uses constant-time comparison and a bounded five-minute window', () => {
  const require = createRequire(import.meta.url);
  const verifierPath = require.resolve('standardwebhooks');
  const verifierSource = readFileSync(verifierPath, 'utf8');
  const comparisonSource = readFileSync(join(dirname(verifierPath), 'timing_safe_equal.js'), 'utf8');

  assert.match(verifierSource, /WEBHOOK_TOLERANCE_IN_SECONDS = 5 \* 60/);
  assert.match(verifierSource, /now - timestamp > WEBHOOK_TOLERANCE_IN_SECONDS/);
  assert.match(verifierSource, /timestamp > now \+ WEBHOOK_TOLERANCE_IN_SECONDS/);
  assert.match(verifierSource, /timingSafeEqual\)\(encoder\.encode\(signature\), encoder\.encode\(expectedSignature\)\)/);
  assert.match(comparisonSource, /out \|= a\.getUint8\(i\) \^ b\.getUint8\(i\)/);
});

test('receiver accepts the cross-language signature vector once', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const seen = new InMemoryWebhookIdStore();
  const event = verifyAiurWebhook(body, headers, secret, seen);

  assert.equal(event.id, 101);
  assert.equal(event.refs.ticket, '5695');
  assert.throws(() => verifyAiurWebhook(body, headers, secret, seen), DuplicateWebhookError);
});

test('receiver accepts both edges of the five-minute timestamp window', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);

  for (const offset of [-300, 300]) {
    assert.equal(
      verifyAiurWebhook(body, signedHeaders(timestamp + offset), secret, new InMemoryWebhookIdStore()).id,
      101,
    );
  }
});

test('receiver rejects missing, wrong, stale, future, and body-mismatched deliveries', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const variants = [
    [{ ...headers, 'webhook-signature': undefined }, body],
    [{ ...headers, 'webhook-signature': 'v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' }, body],
    [signedHeaders(timestamp - 301), body],
    [signedHeaders(timestamp + 301), body],
    [headers, body.replace('running', 'paused')],
  ];

  for (const [variantHeaders, variantBody] of variants) {
    assert.throws(() => verifyAiurWebhook(variantBody, variantHeaders, secret, new InMemoryWebhookIdStore()));
  }
});

test('receiver rejects a signed body whose event ID differs from its delivery ID', (context) => {
  context.mock.method(Date, 'now', () => timestamp * 1_000);
  const mismatched = body.replace('"id":101', '"id":102');

  assert.throws(() =>
    verifyAiurWebhook(
      mismatched,
      signedHeaders(timestamp, mismatched),
      secret,
      new InMemoryWebhookIdStore(),
    ),
  );
});

function signedHeaders(deliveryTimestamp, signedBody = body) {
  return {
    'webhook-id': webhookId,
    'webhook-timestamp': String(deliveryTimestamp),
    'webhook-signature': new Webhook(secret).sign(
      webhookId,
      new Date(deliveryTimestamp * 1_000),
      signedBody,
    ),
  };
}
