import assert from 'node:assert/strict';
import test from 'node:test';
import { contractCases, validateVoiceConverse, voiceConverse } from '../scripts/validate.mjs';

for (const { name, fixture, validate } of contractCases) {
  test(`${name} golden fixture validates`, () => {
    assert.equal(validate(fixture), true, JSON.stringify(validate.errors));
  });

  test(`${name} requires its contract marker`, () => {
    const missing = structuredClone(fixture);
    delete missing.contract;
    assert.equal(validate(missing), false);
  });

  test(`${name} rejects another contract version`, () => {
    const wrongVersion = structuredClone(fixture);
    wrongVersion.contract_version = 2;
    assert.equal(validate(wrongVersion), false);
  });

  test(`${name} permits additive fields within v1`, () => {
    assert.equal(validate({ ...fixture, future_field: true }), true, JSON.stringify(validate.errors));
  });
}

test('voice converse v1 golden frames validate and accept additive fields', () => {
  assert.equal(validateVoiceConverse(voiceConverse), true);
  assert.equal(validateVoiceConverse(voiceConverse.map((frame) => ({ ...frame, future_field: true }))), true);
  assert.equal(validateVoiceConverse([{ ...voiceConverse[0], v: 2 }]), false);
});

test('ticket progress preserves explicitly unknown readings', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'ticket progress');
  const unknown = { ...fixture, phase: { status: 'unknown' }, progress: { status: 'unknown' } };
  assert.equal(validate(unknown), true, JSON.stringify(validate.errors));
});

test('ticket usage accepts stale and known-empty states', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'ticket usage');
  const stale = { ...fixture, state: 'stale', freshness: { ...fixture.freshness, status: 'stale' } };
  const knownEmpty = structuredClone(fixture);
  knownEmpty.state = 'known_empty';
  knownEmpty.totals.api_equivalent.coverage.status = 'none';
  assert.equal(validate(stale), true, JSON.stringify(validate.errors));
  assert.equal(validate(knownEmpty), true, JSON.stringify(validate.errors));
});

test('spend-cap reached event requires the distinct budget_exhausted end state', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'ticket spend cap reached');
  for (const wrong of ['failed', 'cancelled', null]) {
    assert.equal(validate({ ...fixture, end_state: wrong }), false);
  }
});

test('ticket cancel reserves exit evidence for an observed process exit', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'ticket cancel');

  for (const status of ['still_running', 'kill_failed', 'generation_changed']) {
    const nonExit = structuredClone(fixture);
    nonExit.process = {
      ...nonExit.process,
      status,
      exit_status: null,
      exited_at: null,
    };
    assert.equal(validate(nonExit), true, JSON.stringify(validate.errors));
  }

  const falseSuccess = structuredClone(fixture);
  falseSuccess.process.status = 'still_running';
  assert.equal(validate(falseSuccess), false);

  const invented = structuredClone(fixture);
  invented.process.status = 'queued';
  assert.equal(validate(invented), false);

  const unboundedReason = structuredClone(fixture);
  unboundedReason.process.exit_status = 'arbitrary_runtime_term';
  assert.equal(validate(unboundedReason), false);
});

test('status accepts nullable polling and structured CI results emitted by the presenter', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'status');
  const status = structuredClone(fixture);
  status.polling = null;
  status.running[0].ci = {
    decision: 'passed',
    pr_number: 5698,
    head_sha: '0123456789abcdef',
    'draft?': false,
  };
  assert.equal(validate(status), true, JSON.stringify(validate.errors));
});

test('ticket accepts the live retrying shape and absent capabilities', () => {
  const { fixture, validate } = contractCases.find(({ name }) => name === 'ticket');
  const retrying = structuredClone(fixture);
  retrying.status = 'retrying';
  retrying.running = null;
  retrying.capabilities = null;
  retrying.attempts = { restart_count: 1, current_retry_attempt: 2 };
  retrying.retry = {
    attempt: 2,
    due_at: '2026-10-23T12:01:00Z',
    error: 'provider unavailable',
    worker_host: 'worker.example',
    workspace_path: '/var/lib/aiur/5698',
    state: 'rework',
    waiting_reason: 'backing_off',
    open_decision_count: 0,
    open_decision_count_health: 'healthy',
    ci: {
      decision: 'failed',
      pr_number: 5698,
      head_sha: '0123456789abcdef',
      'draft?': false,
    },
    review: 'not_started',
  };
  retrying.last_error = 'provider unavailable';
  assert.equal(validate(retrying), true, JSON.stringify(validate.errors));
});
