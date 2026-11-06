import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
import * as packageIndex from '../src/index.js';

// A published `index.d.ts` is only useful if it describes the module beside it.
// Node cannot type-check here, so this pins the names: every declared value must
// exist at runtime, and every runtime export must be declared.
const declarations = readFileSync(new URL('../src/index.d.ts', import.meta.url), 'utf8');

const declaredValues = [...declarations.matchAll(/^export declare (?:const|class|function) (\w+)/gm)]
  .map((match) => match[1])
  .sort();
const runtimeValues = Object.keys(packageIndex).sort();

test('every value the types declare exists at runtime', () => {
  const missing = declaredValues.filter((name) => !(name in packageIndex));
  assert.deepEqual(missing, [], `declared but not exported: ${missing.join(', ')}`);
});

test('every runtime export is declared in the types', () => {
  const undeclared = runtimeValues.filter((name) => !declaredValues.includes(name));
  assert.deepEqual(undeclared, [], `exported but not declared: ${undeclared.join(', ')}`);
});

test('the edge kinds the types list are the kinds the package accepts', () => {
  const declaredKinds = declarations
    .match(/export type EdgeKind = ([^;]+);/)[1]
    .match(/'([a-z_]+)'/g)
    .map((quoted) => quoted.replace(/'/g, ''));
  assert.deepEqual([...packageIndex.EDGE_TYPES].sort(), declaredKinds.sort());
});
