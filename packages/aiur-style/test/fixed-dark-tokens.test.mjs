import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildTokens, tokens } from '../src/tokens/build.mjs';

test('fixed-dark chassis ink aliases come from the dark palette outside themed overrides', () => {
  const output = mkdtempSync(join(tmpdir(), 'aiur-fixed-dark-'));
  try {
    buildTokens(output);
    const css = readFileSync(join(output, 'tokens.css'), 'utf8');
    const root = css.split('color-scheme: light;')[0];
    for (const name of ['fg', 'accent']) {
      const declaration = `--aiur-color-${name}-dark: ${tokens.dark[`color.${name}`]};`;
      assert.ok(root.includes(declaration), declaration);
      assert.equal(css.split(`--aiur-color-${name}-dark:`).length - 1, 1);
    }
  } finally {
    rmSync(output, { recursive: true, force: true });
  }
});
