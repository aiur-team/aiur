import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import test from 'node:test';

import {
  COMMAND_STATES,
  LIST_STATES,
  MEDIA_KINDS,
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

  assert.match(html, /<a class="aiur-command-media" data-part="media" href="https:\/\/github.com\/aiur-team\/aiur\/issues\/42"/);
  assert.match(html, /data-media-kind="path"/);
  assert.doesNotMatch(html, /href="javascript:/);
});

const typedMedia = [
  {
    kind: 'image',
    mime_type: 'image/png',
    attachment_id: 'med_cover',
    alt_text: 'Cover art: bright meadow',
    caption: 'Cover A',
    width: 1200,
    height: 630,
    locator: { kind: 'attachment', attachment_id: 'med_cover' },
  },
  {
    kind: 'animated_image',
    mime_type: 'image/gif',
    attachment_id: 'med_walkthrough',
    alt_text: 'Opening scene walkthrough',
    caption: 'Opening scene',
    locator: { kind: 'attachment', attachment_id: 'med_walkthrough' },
  },
  {
    kind: 'video',
    mime_type: 'video/mp4',
    attachment_id: 'med_clip',
    alt_text: 'Boss fight clip',
    caption: 'Boss fight',
    locator: { kind: 'attachment', attachment_id: 'med_clip' },
    poster: { kind: 'attachment', attachment_id: 'med_clip_poster' },
  },
  {
    kind: 'audio',
    mime_type: 'audio/mpeg',
    attachment_id: 'med_theme',
    caption: 'Title theme',
    locator: { kind: 'attachment', attachment_id: 'med_theme' },
  },
];

test('every typed media kind has a documented token', () => {
  assert.deepEqual(MEDIA_KINDS, ['image', 'animated_image', 'video', 'audio']);
});

test('typed media renders accessible image, animated, video and audio elements', () => {
  const html = renderCommand(
    { ...pending, media: typedMedia },
    { mediaBaseUrl: 'https://aiur.example.test' },
  );

  assert.match(html, /data-media-kind="image"/);
  assert.match(html, /<img src="https:\/\/aiur\.example\.test\/api\/v1\/commands\/dec_1\/media\/med_cover" alt="Cover art: bright meadow" loading="lazy" decoding="async" width="1200" height="630">/);
  assert.match(html, /data-media-kind="animated_image"/);
  assert.match(html, /<figcaption class="aiur-command-media-caption" data-part="media-caption"><span class="aiur-command-media-kind" data-part="media-kind">Animated<\/span>Opening scene<\/figcaption>/);
  assert.match(html, /<video controls[^>]*poster="https:\/\/aiur\.example\.test\/api\/v1\/commands\/dec_1\/media\/med_clip_poster"/);
  assert.match(html, /<source src="https:\/\/aiur\.example\.test\/api\/v1\/commands\/dec_1\/media\/med_clip" type="video\/mp4">/);
  assert.match(html, /<a href="https:\/\/aiur\.example\.test\/api\/v1\/commands\/dec_1\/media\/med_clip">Open video<\/a>/);
  assert.match(html, /<audio controls[^>]*aria-label="Title theme">/);
  assert.match(html, /<a href="[^"]+\/med_theme">Open audio<\/a>/);
});

test('an https typed locator renders without a host base URL', () => {
  const html = renderCommand({
    ...pending,
    media: [
      {
        kind: 'image',
        mime_type: 'image/jpeg',
        alt_text: 'Screenshot',
        locator: { kind: 'url', value: 'https://cdn.example.test/shot.jpg' },
      },
    ],
  });

  assert.match(html, /<img src="https:\/\/cdn\.example\.test\/shot\.jpg" alt="Screenshot"/);
  assert.doesNotMatch(html, /Media unavailable/);
});

test('an attachment without a host media base URL falls back instead of breaking', () => {
  const html = renderCommand({ ...pending, media: [typedMedia[0]] });

  assert.match(html, /role="status"><strong>Media unavailable<\/strong>/);
  assert.match(html, /This image\/png item could not be resolved/);
  assert.doesNotMatch(html, /<img src=/);
});

test('a non-https typed locator is refused', () => {
  const html = renderCommand({
    ...pending,
    media: [
      {
        kind: 'image',
        mime_type: 'image/png',
        alt_text: 'Screenshot',
        locator: { kind: 'url', value: 'javascript:alert(1)' },
      },
    ],
  });

  assert.doesNotMatch(html, /href="javascript:/);
  assert.doesNotMatch(html, /src="javascript:/);
  assert.match(html, /Media unavailable/);
});

test('option media renders beside its option, not inside the label', () => {
  const html = renderCommand(
    {
      ...pending,
      options: [
        { ...pending.options[0], media: [typedMedia[0]] },
        pending.options[1],
      ],
    },
    { mediaBaseUrl: 'https://aiur.example.test' },
  );

  assert.match(html, /data-option-media="approve"/);
  assert.match(html, /<\/label><div class="aiur-command-option-media" data-option-media="approve" data-part="option-media">/);
  assert.doesNotMatch(html, /data-option-media="hold"/);
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

const pkg = (name) => readFileSync(join(here, '..', name), 'utf8');
const rich = JSON.parse(readFileSync(join(here, 'fixtures/rich-command.json'), 'utf8'));

test('default output is unchanged except for data-part attributes', () => {
  const snapshot = JSON.parse(readFileSync(join(here, 'fixtures/default-output.json'), 'utf8'));
  const strip = (html) => html.replace(/ data-part="[a-z-]+"/g, '');
  const rendered = {};

  for (const f of fixtures) rendered[`${f.expected_state}:${f.projection.decision_id}`] = renderCommand({ ...f.projection, state: f.expected_state });
  for (const s of ['pending', 'conflict', 'answered']) rendered[`rich:${s}`] = renderCommand({ ...rich, state: s }, { answerUrl: '/a', mediaBaseUrl: 'https://aiur.test' });
  for (const s of ['loading', 'empty', 'unavailable', 'error']) rendered[`list:${s}`] = renderList({ status: s, error: { reason: 'boom' } });
  rendered['list:ready'] = renderList({ status: 'ready', commands: [rich] });

  assert.deepEqual(Object.keys(rendered), Object.keys(snapshot));
  for (const [key, html] of Object.entries(rendered)) assert.equal(strip(html), snapshot[key], key);
});

test('every documented part is in the README and rendered', () => {
  const readme = pkg('README.md');
  const theming = readme.slice(readme.indexOf('## Theming'), readme.indexOf('Import the optional stylesheet'));
  const documented = [...theming.matchAll(/^\| ((?:`[a-z-]+`(?:, )?)+) \|/gm)]
    .flatMap((m) => [...m[1].matchAll(/`([a-z-]+)`/g)].map((p) => p[1]))
    .filter((p) => p !== 'data-part');
  const html = [
    ...['pending', 'conflict', 'answered', 'expired', 'error'].map((s) => renderCommand({ ...rich, state: s }, { mediaBaseUrl: 'https://aiur.test' })),
    renderCommand({ ...rich, state: 'revised' }),
    renderCommand({ ...rich, state: 'pending', media: [{ kind: 'video', mime_type: 'video/mp4', locator: { kind: 'attachment', attachment_id: 'x' } }, { kind: 'path', value: 'a' }] }),
    renderList({ status: 'empty' }),
    renderList({ status: 'ready', commands: [rich] }),
  ].join('\n');

  assert.ok(documented.length >= 25, `README documents ${documented.length} parts`);
  for (const part of documented) assert.ok(html.includes(`data-part="${part}"`), `missing part ${part}`);
  for (const [, part] of html.matchAll(/data-part="([a-z-]+)"/g)) assert.ok(documented.includes(part), `undocumented part ${part}`);
});

test('stylesheet uses only documented custom properties', () => {
  const readme = pkg('README.md');
  const used = new Set(pkg('src/theme.css').match(/--aiur-command-[a-z-]+/g));

  assert.ok(used.size >= 8);
  for (const prop of used) assert.ok(readme.includes(`\`${prop}\``), `undocumented ${prop}`);
  for (const prop of readme.match(/--aiur-command-[a-z-]+/g)) assert.ok(used.has(prop), `unused ${prop}`);
});

test('custom labels render and are escaped', () => {
  const labels = { submit: 'Go <b>now</b>', legend: 'Pick "one"', recommended: 'Top & best', recorded: 'Saved', revised: 'Edited' };
  const pendingHtml = renderCommand(rich, { labels });
  const answered = renderCommand({ ...rich, state: 'answered' }, { labels });
  const revised = renderCommand({ ...rich, state: 'revised' }, { labels });

  assert.match(pendingHtml, />Go &lt;b&gt;now&lt;\/b&gt;<\/button>/);
  assert.match(pendingHtml, /<legend data-part="legend">Pick &quot;one&quot;<\/legend>/);
  assert.match(pendingHtml, /chip">Top &amp; best</);
  assert.match(pendingHtml, />Top &amp; best: Approve</);
  assert.ok(!pendingHtml.includes('<b>now'));
  assert.match(answered, />Saved</);
  assert.match(revised, />Edited</);
  assert.ok(!pendingHtml.includes('Record answer'));
});
