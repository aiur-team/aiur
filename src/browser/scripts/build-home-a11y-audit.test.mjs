import { test } from 'node:test'
import assert from 'node:assert/strict'
import { boardAudit, contrastRatio } from '../tests/support/build-home-a11y-audit.mjs'
import { expectAuditClean } from '../tests/support/browser-helpers.mjs'

const node = key => ({ any: [{ data: { messageKey: key } }], all: [], none: [] })
const audit = (key, id = 'color-contrast') => ({ violations: [], incomplete: [{ id, nodes: [node(key)] }] })

test('only overlap-caused contrast incompletes are exempted', () => {
  const input = audit('bgOverlap')
  expectAuditClean(boardAudit(input))
  assert.equal(input.incomplete[0].nodes.length, 1)
  for (const key of ['bgColor', 'fgColor', 'nonBmp', undefined]) {
    assert.throws(() => expectAuditClean(boardAudit(audit(key))))
  }
  const mixed = audit('bgOverlap')
  mixed.incomplete[0].nodes[0].all = node('bgColor').any
  assert.throws(() => expectAuditClean(boardAudit(mixed)))
  const violation = { violations: [{ id: 'color-contrast', nodes: [node('bgOverlap')] }], incomplete: [] }
  assert.throws(() => expectAuditClean(boardAudit(violation)))
  assert.deepEqual(boardAudit(audit('bgOverlap', 'other-rule')), audit('bgOverlap', 'other-rule'))
})

test('token arithmetic distinguishes AA failures from passing text pairs', () => {
  assert.equal(contrastRatio('#000000', '#ffffff'), 21)
  assert.equal(contrastRatio('#ffffff', '#ffffff'), 1)
  assert.ok(contrastRatio('#777269', '#ffffff') >= 4.5)
  assert.ok(contrastRatio('#777269', '#f4f2ed') < 4.5)
  assert.ok(Math.abs(contrastRatio('#777269', '#ffffff') - 4.7778337244) < 0.000001)
  assert.equal(contrastRatio('#777269', '#ffffff'), contrastRatio('#ffffff', '#777269'))
  assert.throws(() => contrastRatio('transparent', '#ffffff'))
})
