import assert from 'node:assert/strict';
import test from 'node:test';

import { renderCommand } from '../src/render.mjs';

const embed = {
  kind: 'embed',
  mime_type: 'text/html',
  attachment_id: 'med_level3',
  alt_text: 'Level 3 playable build',
  caption: 'Try the jump',
  locator: { kind: 'url', value: 'https://play.example.test/builds/42?level=3&mode=demo' },
};

const command = {
  state: 'pending',
  decision_id: 'dec_1',
  question: 'Does level 3 feel right?',
  options: [{ id: 'ship', label: 'Ship it', media: [embed] }],
  media: [],
  actions: { answer: true },
};

// The only iframe is inside the inert template, so nothing loads before a click.
function liveMarkup(html) {
  return html.replace(/<template[\s\S]*?<\/template>/g, '');
}

test('an embed renders a click-to-load sandboxed iframe under its option', () => {
  const html = renderCommand(command);
  const option = html.slice(html.indexOf('data-option-media="ship"'));

  assert.match(option, /data-media-kind="embed"/);
  assert.match(option, /<button type="button" data-part="embed-load" data-aiur-embed-load>Load Level 3 playable build<\/button>/);
  assert.match(option, /<template data-part="embed-frame"><iframe src="https:\/\/play\.example\.test\/builds\/42\?level=3&amp;mode=demo" title="Level 3 playable build" sandbox="allow-scripts" referrerpolicy="no-referrer"><\/iframe><\/template>/);
  assert.doesNotMatch(liveMarkup(html), /<iframe/);
  assert.doesNotMatch(html, /allow-same-origin|allow-top-navigation|allow-popups/);
});

test('a client without iframe support gets the alt text and a link', () => {
  const html = renderCommand(command, { embeds: false });

  assert.doesNotMatch(html, /<iframe|<template|data-aiur-embed-load/);
  assert.match(html, /data-part="embed-fallback">Level 3 playable build <a href="https:\/\/play\.example\.test\/builds\/42\?level=3&amp;mode=demo" target="_blank" rel="noopener noreferrer">Open in a new tab<\/a><\/p>/);
});

test('an embed never frames the attachment route', () => {
  const html = renderCommand(
    { ...command, options: [], media: [{ ...embed, locator: { kind: 'attachment', attachment_id: 'med_level3' } }] },
    { mediaBaseUrl: 'https://aiur.example.test' },
  );

  assert.doesNotMatch(html, /<iframe|\/media\/med_level3/);
  assert.match(html, /Media unavailable/);
});
