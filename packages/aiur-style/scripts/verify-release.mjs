#!/usr/bin/env node

import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(import.meta.url);
const packageRoot = resolve(dirname(script), '..');

function verifyRelease(tag, root) {
  const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
  if (!semver.test(version) || tag !== `aiur-style-v${version}`) {
    throw new Error(`Tag ${tag ?? '<missing>'} must match aiur-style-v${version} (stable semver)`);
  }
  const changelog = readFileSync(join(root, 'CHANGELOG.md'), 'utf8');
  const heading = new RegExp(`^## \\[${version.replaceAll('.', '\\.')}\\](?:[ \\t]+-[ \\t]+[^\\r\\n]+)?[ \\t]*$`, 'm');
  if (!heading.test(changelog)) {
    throw new Error(`CHANGELOG.md is missing the release heading for ${version}`);
  }
  const check = spawnSync('npm', ['run', 'check-dist'], { cwd: root, stdio: 'inherit' });
  if (check.error) throw check.error;
  if (check.status !== 0) throw new Error('check-dist failed; release aborted');
  console.log(`Release verified: ${version}`);
}

// Keep node:test coverage here to respect AS-14's three-file scope.
// The workflow runs this explicitly; npm test's existing glob is unchanged.
async function selfTest() {
  const { test } = await import('node:test');
  const assert = await import('node:assert/strict');
  const cases = [
    ['accepts matching tag and changelog and runs check-dist', 'aiur-style-v0.1.0', '## [0.1.0] - 2026-10-01', 0, 0, /Release verified: 0\.1\.0/],
    ['rejects tag/version mismatch', 'aiur-style-v0.1.1', '## [0.1.0]', 0, 1, /must match aiur-style-v0\.1\.0/],
    ['rejects missing changelog entry', 'aiur-style-v0.1.0', '## [0.1.1]', 0, 1, /missing the release heading/],
    ['rejects a version mentioned only in prose', 'aiur-style-v0.1.0', 'Next release: [0.1.0]', 0, 1, /missing the release heading/],
    ['rejects stale dist', 'aiur-style-v0.1.0', '## [0.1.0]', 1, 1, /check-dist failed/],
    ['rejects missing tag', undefined, '## [0.1.0]', 0, 1, /must match/],
    ['rejects unrelated tag prefix', 'v0.1.0', '## [0.1.0]', 0, 1, /must match/],
  ];
  for (const [name, tag, changelog, checkExit, exit, output] of cases) {
    test(name, () => {
      const root = mkdtempSync(join(tmpdir(), 'aiur-style-release-test-'));
      try {
        writeFileSync(join(root, 'package.json'), JSON.stringify({
          version: '0.1.0', scripts: { 'check-dist': `node -e "console.log('DIST_CHECK_EXECUTED'); process.exit(${checkExit})"` },
        }));
        writeFileSync(join(root, 'CHANGELOG.md'), `${changelog}\n`);
        const result = spawnSync(process.execPath, [script, tag ?? '', root], { encoding: 'utf8' });
        assert.equal(result.status, exit, result.stdout + result.stderr);
        assert.match(result.stdout + result.stderr, output);
        if (exit === 0) assert.match(result.stdout, /DIST_CHECK_EXECUTED/);
        if (/must match|missing the release heading/.test(output.source)) {
          assert.doesNotMatch(result.stdout, /DIST_CHECK_EXECUTED/);
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }
}

if (process.argv[2] === '--self-test') {
  await selfTest();
} else {
  try {
    verifyRelease(process.argv[2] || process.env.GITHUB_REF_NAME, process.argv[3] ?? packageRoot);
  } catch (error) {
    console.error(`Release verification failed: ${error.message}`);
    process.exitCode = 1;
  }
}
