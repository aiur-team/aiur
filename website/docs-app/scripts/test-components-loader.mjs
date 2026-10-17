import assert from 'node:assert/strict'
import { test } from 'node:test'
import { projectDirectory } from '../reference/components-projection.mjs'

function component(overrides = {}) {
  return {
    id: 'example', name: 'Example', summary: 'An example component.', status: 'core', kind: 'in-app',
    install: { type: 'included' }, requires: [], optional: [], capabilities: [], config: [], env: [], docs: [],
    ...overrides
  }
}

function feature(overrides = {}) {
  return { id: 'MP-TEST', name: 'Future', summary: 'An upcoming feature.', extends: [], adds: [], public: true, shipped_in: null, ...overrides }
}

function project(components = [component()], features = []) {
  return projectDirectory({ components, features })
}

test('projects_only_public_fields', () => {
  const value = component({ paths: ['private'], facades: ['Secret'], layer: 5, allowlist: ['private'], install: { type: 'included', token: 'secret' } })
  assert.deepEqual(project([value]).components, [component()])
})

test('drops_feature_ids_and_flags', () => {
  assert.deepEqual(project(undefined, [feature()]).planned, [{ name: 'Future', summary: 'An upcoming feature.', extends: [], adds: [] }])
})

test('planned_lists_only_public_unshipped', () => {
  const planned = project(undefined, [feature(), feature({ public: false, name: 'Private' }), feature({ shipped_in: '1.0', name: 'Shipped' })]).planned
  assert.deepEqual(planned.map((entry) => entry.name), ['Future'])
})

test('planned_component_hidden_from_components', () => {
  assert.deepEqual(project([component({ status: 'planned' })]).components, [])
})

test('missing_summary_throws', () => {
  const value = component()
  delete value.summary
  assert.throws(() => project([value]), /example: invalid or missing summary/)
})

test('empty_manifest_throws', () => {
  assert.throws(() => projectDirectory({}), /manifest: invalid or missing components or features/)
  assert.throws(() => project([]), /manifest/)
})

test('unknown_status_throws', () => {
  assert.throws(() => project([component({ status: 'mystery' })]), /example: invalid or missing status/)
})

test('validates_public_arrays_and_install', () => {
  assert.throws(() => project([component({ docs: 'guide' })]), /example: invalid or missing docs/)
  assert.throws(() => project([component({ env: [42] })]), /example: invalid or missing env/)
  assert.throws(() => project([component({ install: { type: 'npm' } })]), /example: invalid or missing install.package/)
  assert.throws(() => project([component({ install: { type: 'unknown' } })]), /example: invalid or missing install/)
  assert.throws(() => project(undefined, [feature({ adds: undefined })]), /MP-TEST: invalid or missing adds/)
})

test('sorts_names_case_insensitively_within_status', () => {
  const values = [component({ id: 'b', name: 'Beta' }), component({ id: 'a', name: 'alpha' }), component({ id: 'o', name: 'Aardvark', status: 'optional' })]
  assert.deepEqual(project(values).components.map((entry) => entry.id), ['a', 'b', 'o'])
  assert.deepEqual(project(undefined, [feature({ name: 'Beta' }), feature({ name: 'alpha' })]).planned.map((entry) => entry.name), ['alpha', 'Beta'])
})
