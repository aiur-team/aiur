import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadBuildJs } from './export-build-home-fixtures.mjs';

const root = fileURLToPath(new URL('../../test/fixtures/build_home/', import.meta.url));
const rows = [
  ['', ''],
  ['view=gantt', 'view=gantt'],
  ['view=list', 'view=list'],
  ['trees=1', 'trees=1'],
  ['live=min', 'live=min'],
  ['span=7', 'span=7'],
  ['feature=f-docs', 'feature=f-docs'],
  ['feature=f-docs&fmode=compact', 'feature=f-docs&fmode=compact'],
  ['epic=bugs,docs', 'epic=bugs,docs'],
  ['model=claude', 'model=claude'],
  ['tstate=in+progress,queued', 'tstate=in+progress,queued'],
  ['astate=paused,parked', 'astate=paused,parked'],
  ['ticket=2748', 'ticket=2748'],
  ['view=gantt&trees=1&live=min&span=7&feature=f-docs&fmode=compact&epic=bugs,docs&model=claude&tstate=in+progress&astate=error,retries,command&ticket=2748',
    'view=gantt&trees=1&live=min&span=7&feature=f-docs&fmode=compact&epic=bugs,docs&model=claude&tstate=in+progress&astate=error,retries,command&ticket=2748'],
  ['astate=bogus,,active,active', 'astate=active', 'Invalid/empty list values and duplicates are dropped.'],
  ['model=none', '', 'The design has no none model option.'],
  ['models=7&example=dense', '', 'Demo parameters are dropped.'],
  ['unknown=x', '', 'Unknown keys are dropped.'],
  ['span=7&view=gantt', 'view=gantt&span=7', 'Key order is fixed.'],
  ['view=list&view=gantt', 'view=gantt', 'Plug keeps the last duplicate key; the design reads the first.'],
  ['span=7.0', '', 'Only complete integer span strings are accepted.'],
  ['span=+7', '', 'Leading whitespace accepted by JavaScript coercion is rejected.'],
  ['span=0x7', '', 'Hexadecimal JavaScript coercion is rejected.'],
  ['ticket=AIUR-12', '', 'Ticket ids must be positive decimal digits.'],
  ['ticket=007', 'ticket=7', 'Leading zeros in ticket ids are canonicalized.'],
  ['feature=%3Cscript%3E', '', 'Feature slugs are shape-checked.'],
  ['v=1&conditions=alert', 'astate=error,retries,command', 'Legacy Units keys map to home presets.'],
  ['zoom=2&density=compact', ''],
  ['view=graph&span=1&fmode=compact', ''],
];
const cases = rows.map(([query, canonical, differs]) => {
  let output;
  const api = loadBuildJs({
    designDir: root + 'design-source', expose: ['readURL', 'writeURL', 'S'],
    context: { URLSearchParams, location: { search: query ? '?' + query : '', pathname: '/build', hash: '' },
      history: { replaceState: (_a, _b, url) => { output = url; } } },
  });
  api.readURL();
  api.writeURL();
  const design_output = output.split('?')[1] ?? '';
  if (!differs) assert.equal(design_output, canonical, query);
  return { query, canonical, design_output, ...(differs ? { differs } : {}) };
});
const text = JSON.stringify({
  build_js_sha256: createHash('sha256').update(readFileSync(root + 'design-source/assets/build.js')).digest('hex'),
  cases,
}, null, 2) + '\n';
const target = root + 'url_cases.json';
if (process.argv.includes('--check')) assert.equal(readFileSync(target, 'utf8'), text, 'URL golden cases are stale');
else writeFileSync(target, text);
console.log('Build URL golden cases: ' + cases.length + ' checked');
