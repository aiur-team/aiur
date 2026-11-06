import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import test from 'node:test';

import {
  COMMAND_STATES,
  LIST_STATES,
  escapeHtml,
  renderCommand,
  renderList,
  stateLabel,
} from '../src/render.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(readFileSync(join(here, 'fixtures/command-states.json'), 'utf8')).fixtures;

const pending = {
  state: 'pending',
  decision_id: 'dec_1',
  question: 'Ship the build?',
  ticket: { identifier: '42', title: 'Game', url: 'https://example.test/42' },
  blocking: true,
  options: [
    { id: 'approve', label: 'Approve', description: 'Ship it' },
    { id: 'hold', label: 'Hold', description: null },
  ],
  recommendation: { option_id: 'approve', label: 'Approve' },
  free_response: { allowed: true, required: false },
  answer: null,
  conflict: null,
  media: [{ kind: 'url', value: 'https://github.com/aiur-team/aiur/issues/42' }],
  actions: { answer: true, revise: false, enrich: false },
};

test('every contract state has a renderer label', () => {
  for (const state of COMMAND_STATES) {
    assert.notEqual(stateLabel(state), 'Command', `missing label for ${state}`);
  }

  for (const state of LIST_STATES) {
    assert.equal(typeof state, 'string');
  }
});

test('shared fixtures render the state the Elixir contract derives', () => {
  for (const fixture of fixtures) {
    const html = renderCommand({ ...fixture.projection, state: fixture.expected_state });
    assert.match(
      html,
      new RegExp(`data-command-state="${fixture.expected_state}"`),
      `fixture ${fixture.name} did not render ${fixture.expected_state}`,
    );
  }
});

test('a pending Command renders its options, recommendation and free response', () => {
  const html = renderCommand(pending, { answerUrl: '/api/v1/commands/dec_1/answer' });

  assert.match(html, /data-command-state="pending"/);
  assert.match(html, /data-command-recommendation="approve"/);
  assert.match(html, /name="option_id" value="approve" checked/);
  assert.match(html, /name="option_id" value="hold"/);
  assert.match(html, /name="custom_response"/);
  assert.match(html, /action="\/api\/v1\/commands\/dec_1\/answer"/);
  assert.match(html, /data-decision-id="dec_1"/);
});

test('a pending Command without options marks the free response required', () => {
  const html = renderCommand({
    ...pending,
    options: [],
    recommendation: null,
    free_response: { allowed: true, required: true },
  });

  assert.doesNotMatch(html, /name="option_id"/);
  assert.match(html, /<textarea name="custom_response"[^>]*required/);
});

test('an answered Command shows the recorded answer and no form', () => {
  const html = renderCommand({
    ...pending,
    state: 'answered',
    actions: { answer: false, revise: true, enrich: false },
    answer: { action_id: 'act_1', decision_version: 2, selected_option_id: 'approve' },
  });

  assert.match(html, /data-command-state="answered"/);
  assert.match(html, /data-action-id="act_1"/);
  assert.match(html, /Approve/);
  assert.doesNotMatch(html, /data-aiur-command-form/);
});

test('a revised Command labels its answer as revised', () => {
  const html = renderCommand({
    ...pending,
    state: 'revised',
    actions: { answer: false, revise: true, enrich: false },
    answer: { action_id: 'act_2', decision_version: 4, custom_response: 'After the tests' },
  });

  assert.match(html, /Revised answer/);
  assert.match(html, /After the tests/);
});

test('an expired Command explains that it is no longer answerable', () => {
  const html = renderCommand({ ...pending, state: 'expired', reason: 'expired', actions: { answer: false, revise: false, enrich: false } });

  assert.match(html, /data-command-state="expired"/);
  assert.match(html, /no longer answerable/);
  assert.doesNotMatch(html, /data-aiur-command-form/);
});

test('a conflict names the winner instead of offering a form', () => {
  const html = renderCommand({
    ...pending,
    state: 'conflict',
    reason: 'already_answered',
    actions: { answer: false, revise: false, enrich: false },
    conflict: { kind: 'already_answered', winner: { actor: 'the Executor' } },
  });

  assert.match(html, /data-command-state="conflict"/);
  assert.match(html, /data-command-reason="already_answered"/);
  assert.match(html, /Already answered by the Executor/);
  assert.doesNotMatch(html, /data-aiur-command-form/);
});

test('an error state carries the message', () => {
  const html = renderCommand({
    ...pending,
    state: 'error',
    reason: 'validation_failed',
    message: 'Answer failed validation',
    actions: { answer: false, revise: false, enrich: false },
  });

  assert.match(html, /data-command-state="error"/);
  assert.match(html, /role="alert"/);
  assert.match(html, /Answer failed validation/);
});

test('typed media renders as a link only for https values', () => {
  const html = renderCommand({
    ...pending,
    media: [
      { kind: 'url', value: 'https://github.com/aiur-team/aiur/issues/42' },
      { kind: 'path', value: '/var/tmp/evidence.png' },
      { kind: 'url', value: 'javascript:alert(1)' },
    ],
  });

  assert.match(html, /<a class="aiur-command-media" href="https:\/\/github.com\/aiur-team\/aiur\/issues\/42"/);
  assert.match(html, /data-media-kind="path"/);
  assert.doesNotMatch(html, /href="javascript:/);
});

test('question, options and ticket text are HTML-escaped', () => {
  const html = renderCommand({
    ...pending,
    question: '<script>alert(1)</script>',
    ticket: { identifier: '42', title: '<img src=x onerror=alert(1)>', url: 'https://example.test/?a="b"' },
    options: [{ id: 'a" onmouseover="alert(1)', label: '<b>bold</b>', description: null }],
    recommendation: null,
  });

  assert.doesNotMatch(html, /<script>alert/);
  assert.doesNotMatch(html, /<img src=x/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /&quot;/);
  assert.ok(escapeHtml('<b>&') === '&lt;b&gt;&amp;');
});

test('list states cover loading, empty, ready and error', () => {
  assert.match(renderList({ status: 'loading', commands: [], count: 0 }), /data-command-list-state="loading"/);
  assert.match(renderList({ status: 'empty', commands: [], count: 0 }), /No Commands need you right now/);
  assert.match(renderList({ status: 'empty', commands: [], count: 0 }), /data-command-list-state="empty"/);

  const ready = renderList({ status: 'ready', commands: [pending], count: 1 });
  assert.match(ready, /data-command-list-state="ready"/);
  assert.match(ready, /data-command-state="pending"/);

  const failed = renderList({ status: 'error', commands: [], count: 0, error: { reason: 'store_unavailable' } });
  assert.match(failed, /data-command-list-state="error"/);
  assert.match(failed, /store_unavailable/);
});
