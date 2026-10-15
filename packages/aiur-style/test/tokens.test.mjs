import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { tokens, breakpoints, contrastPairs } from '../dist/tokens.js';

const definitions = JSON.parse(fs.readFileSync(new URL('../src/tokens/tokens.json', import.meta.url), 'utf8'));
const css = fs.readFileSync(new URL('../dist/tokens.css', import.meta.url), 'utf8');

function luminance(hex) {
  assert.match(hex, /^#[\da-f]{6}$/i, 'Contrast pairs must use opaque hex colors');
  const channels = hex.slice(1).match(/../g).map(channel => parseInt(channel, 16) / 255);
  const linear = channels.map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return linear.reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
}

function checkContrast(foreground, background, threshold) {
  const [low, high] = [luminance(foreground), luminance(background)].sort((a, b) => a - b);
  return (high + 0.05) / (low + 0.05) >= threshold;
}

const substitutions = {
  'faint/bg': 'faint-on-bg', 'faint/bg-2': 'faint-on-bg-2', 'faint/bg-app': 'faint-on-bg-app',
  'accent/bg-2': 'accent-on-bg-2', 'accent/surface-2': 'accent-on-surface-2',
};

test('all plan contrast pairs are exported, including readable text substitutions', () => {
  const expected = ['fg', 'muted', 'faint', 'accent', 'accent-ink'].flatMap(foreground =>
    ['bg', 'bg-2', 'bg-app', 'surface', 'surface-2'].map(background => ({
      foreground: `color.${substitutions[`${foreground}/${background}`] ?? foreground}`,
      background: `color.${background}`, threshold: 4.5,
    })));
  expected.push(...['fill', 'fill-hover', 'fill-pressed'].map(background =>
    ({ foreground: 'color.on-fill', background: `color.${background}`, threshold: 4.5 })));
  expected.push(...['bg', 'bg-app'].map(background =>
    ({ foreground: 'color.focus', background: `color.${background}`, threshold: 3 })));
  expected.push({ foreground: 'color.on-blocking', background: 'color.blocking', threshold: 4.5 });
  assert.deepEqual(contrastPairs, expected);
});

for (const theme of ['light', 'dark']) {
  test(`${theme}: every resolved contrast pair meets its threshold`, () => {
    for (const pair of contrastPairs) {
      assert.ok(checkContrast(tokens[theme][pair.foreground], tokens[theme][pair.background], pair.threshold),
        `${theme}: ${pair.foreground} on ${pair.background} must meet ${pair.threshold}:1`);
    }
  });
}

test('fill checker rejects old dark accent as a white-text fill', () => {
  const threshold = contrastPairs.find(pair => pair.background === 'color.fill').threshold;
  for (const [background, accepted] of [['#2f86ff', false], ['#1f57c4', true], ['#1a4aa8', true]]) {
    assert.equal(checkContrast('#ffffff', background, threshold), accepted, background);
  }
});

test('fixed brand colors remain unchanged and substitution aliases resolve to existing ink', () => {
  assert.deepEqual(['light', 'dark'].map(theme => tokens[theme]['color.accent']), ['#1f57c4', '#2f86ff']);
  assert.deepEqual(['light', 'dark'].map(theme => tokens[theme]['color.fill']), ['#1f57c4', '#1f57c4']);
  assert.equal(tokens.light['color.faint'], '#6d6450');
  assert.equal(tokens.light['color.accent-on-bg-2'], '#1a4aa8');
  assert.equal(tokens.dark['color.accent-on-surface-2'], '#8fbcff');
  for (const name of ['faint-on-bg', 'faint-on-bg-2', 'faint-on-bg-app']) {
    assert.equal(tokens.light[`color.${name}`], '#5f5645');
    assert.equal(tokens.dark[`color.${name}`], '#8b8f99');
  }
});

// Freeze the ticket's source palette; the live dashboard is being redesigned independently.
test('dashboard status family and elevations preserve the AS-11 source snapshot', () => {
  const expected = {
  "light": {
    "color.good": "#1f9d4d",
    "color.good-ink": "#167038",
    "color.good-soft": "rgba(31, 157, 77, 0.13)",
    "color.good-line": "rgba(31, 157, 77, 0.3)",
    "color.attention": "#b8821a",
    "color.attention-ink": "#75530d",
    "color.attention-soft": "rgba(184, 130, 26, 0.13)",
    "color.attention-line": "rgba(184, 130, 26, 0.32)",
    "color.blocking": "#d23b32",
    "color.blocking-ink": "#a52a23",
    "color.blocking-soft": "rgba(210, 59, 50, 0.11)",
    "color.blocking-line": "rgba(210, 59, 50, 0.3)",
    "color.super": "#8a4fd0",
    "color.super-ink": "#6d3aa8",
    "color.super-soft": "rgba(138, 79, 208, 0.12)",
    "color.super-line": "rgba(138, 79, 208, 0.3)",
    "color.on-blocking": "#ffffff",
    "color.ack": "#0e9e8e",
    "shadow.sm": "0 1px 2px rgba(58, 44, 18, 0.1)",
    "shadow.md": "0 4px 12px -2px rgba(58, 44, 18, 0.22)",
    "shadow.lg": "0 44px 80px -40px rgba(58, 44, 18, 0.3)"
  },
  "dark": {
    "color.good": "#3fb950",
    "color.good-ink": "#74d47f",
    "color.good-soft": "rgba(63, 185, 80, 0.14)",
    "color.good-line": "rgba(63, 185, 80, 0.32)",
    "color.attention": "#e3b341",
    "color.attention-ink": "#f1cf6f",
    "color.attention-soft": "rgba(227, 179, 65, 0.15)",
    "color.attention-line": "rgba(227, 179, 65, 0.34)",
    "color.blocking": "#ff7b72",
    "color.blocking-ink": "#ffa39c",
    "color.blocking-soft": "rgba(255, 123, 114, 0.14)",
    "color.blocking-line": "rgba(255, 123, 114, 0.34)",
    "color.super": "#c69bff",
    "color.super-ink": "#d8bcff",
    "color.super-soft": "rgba(198, 155, 255, 0.15)",
    "color.super-line": "rgba(198, 155, 255, 0.34)",
    "color.on-blocking": "#2a0906",
    "color.ack": "#4fd6c4",
    "shadow.sm": "0 1px 2px rgba(0, 0, 0, 0.35)",
    "shadow.md": "0 4px 12px -2px rgba(0, 0, 0, 0.55)",
    "shadow.lg": "0 40px 90px -40px rgba(0, 0, 0, 0.7)"
  }
};
  for (const theme of ['light', 'dark']) {
    for (const [name, value] of Object.entries(expected[theme])) assert.equal(tokens[theme][name], value, `${theme}: ${name}`);
  }
});

test('CSS contains every token once in each of the three theme blocks', () => {
  assert.equal((css.match(/^\s*color-scheme:/gm) ?? []).length, 3);
  assert.ok(css.startsWith('@layer aiur.tokens {'));
  const blocks = [...css.matchAll(/color-scheme: (?:light|dark);([\s\S]*?)\n\s*}/g)].map(match => match[1]);
  assert.equal(blocks.length, 3);
  for (const block of blocks) {
    const declarations = [...block.matchAll(/(--aiur-[\w-]+):/g)].map(match => match[1]);
    assert.deepEqual(declarations, Object.keys(definitions).map(name => `--aiur-${name.replaceAll('.', '-')}`));
  }
  const bundle = fs.readFileSync(new URL('../dist/aiur-style.css', import.meta.url), 'utf8');
  assert.ok(bundle.startsWith(css), 'Main stylesheet must include generated tokens');
  assert.deepEqual(breakpoints, { shell: 960, features2: 720, features1: 440 });
});

test('token inventory includes every explicit color and non-color token in the plan', () => {
  const plan = fs.readFileSync(new URL('../../../docs/aiur-style/plan.md', import.meta.url), 'utf8');
  const colorSection = plan.split('### 7.1')[1].split('### 7.2')[0];
  for (const match of colorSection.matchAll(/\| `--aiur-(color-[\w-]+)` \| `([^`]+)` \| `([^`]+)`/g)) {
    const name = match[1].replace('color-', 'color.');
    assert.equal(tokens.light[name], match[2], name);
    assert.equal(tokens.dark[name], match[3], name);
  }
  const expected = ['font.display', 'font.body', 'font.mono', 'text.xs', 'text.sm', 'text.md', 'text.lg',
    'text.banner', 'text.summary', 'text.signoff', ...Array.from({ length: 8 }, (_, i) => `space.${i + 1}`),
    ...['sm', 'md', 'box', 'lg', 'xl', 'pill'].map(name => `radius.${name}`),
    ...['sm', 'md', 'lg'].map(name => `shadow.${name}`), 'motion.fast', 'ease.rise', 'ease.standard',
    'layout.nav', 'layout.nav-collapsed', 'layout.measure', 'layout.page-max', 'z.topbar', 'z.banner', 'z.stage'];
  assert.deepEqual(Object.keys(definitions).filter(name => !name.startsWith('color.')).sort(), expected.sort());
  for (const definition of Object.values(definitions)) {
    assert.ok(definition.description && definition.source, 'Every token needs provenance');
  }
});
