import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
import { EDGE_TYPES, STYLES, STYLESHEET_NAME } from '../src/index.js';

const TOKEN = /var\((--aiur-[a-z0-9-]+)/g;
const SPACING_OR_TYPE = /^\s*(font-size|padding|padding-[a-z]+|gap|margin|margin-[a-z]+|border-radius|border-radius-[a-z]+)\s*:/;

test('the package ships exactly one stylesheet', () => {
  assert.equal(STYLESHEET_NAME, 'aiur-build-order.css');
  assert.ok(STYLES.length > 1000);
  assert.match(STYLES, /@layer aiur\.build-order/);
});

test('the stylesheet declares no colour of its own', () => {
  assert.doesNotMatch(STYLES, /#[0-9a-fA-F]{3,8}\b/, 'a hex colour constant');
  assert.doesNotMatch(STYLES, /\b(rgb|rgba|hsl|hsla)\(/, 'a functional colour constant');
});

test('spacing, type and radius come from tokens, not from the stylesheet', () => {
  const raw = STYLES.split('\n')
    .map((line) => line.trim())
    .filter((line) => SPACING_OR_TYPE.test(line))
    .filter((line) => !/:\s*(0|0 [a-z-]+|none|inherit)\s*;/.test(line))
    .filter((line) => !line.includes('var(--aiur-'));

  assert.deepEqual(raw, [], `declarations without a token: ${raw.join(' | ')}`);
});

test('every value the stylesheet reads is an aiur-style token', () => {
  const used = [...new Set([...STYLES.matchAll(TOKEN)].map((match) => match[1]))];
  assert.ok(used.length >= 20, `only ${used.length} tokens used`);

  const defined = aiurStyleTokens();
  if (defined === null) {
    // An installed copy has no sibling aiur-style checkout to compare against.
    assert.ok(used.every((token) => token.startsWith('--aiur-')));
    return;
  }
  const missing = used.filter((token) => !defined.has(token));
  assert.deepEqual(missing, [], `tokens missing from @aiur/style: ${missing.join(', ')}`);
});

test('each typed edge reads its own token, so the five styles cannot collapse', () => {
  for (const kind of EDGE_TYPES) {
    const declaration = new RegExp(`--bo-edge-${kind.replace(/_/g, '-')}:\\s*var\\(--aiur-[a-z0-9-]+\\)`);
    assert.match(STYLES, declaration, `no token for ${kind}`);
  }
});

function aiurStyleTokens() {
  try {
    const path = new URL('../../aiur-style/src/tokens/tokens.json', import.meta.url);
    const tokens = JSON.parse(readFileSync(path, 'utf8'));
    return new Set(Object.keys(tokens).map((key) => `--aiur-${key.replace(/\./g, '-')}`));
  } catch {
    return null;
  }
}
