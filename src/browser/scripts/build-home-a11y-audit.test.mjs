import { test } from 'node:test'
import assert from 'node:assert/strict'
import { boardAudit, contrastRatio } from '../tests/support/build-home-a11y-audit.mjs'
import { expectAuditClean } from '../tests/support/browser-helpers.mjs'

const node = key => ({ target: ['.bd-cx'], any: [{ data: { messageKey: key } }], all: [], none: [] })
const audit = (key, id = 'color-contrast') => ({ violations: [], incomplete: [{ id, nodes: [node(key)] }] })

test('only overlap-caused contrast incompletes are exempted', () => {
  const input = audit('bgOverlap')
  expectAuditClean(boardAudit(input))
  assert.equal(input.incomplete[0].nodes.length, 1)
  for (const key of ['bgColor', 'fgColor', 'nonBmp', 'imgNode', undefined]) {
    assert.throws(() => expectAuditClean(boardAudit(audit(key))))
  }
  const pseudo = audit('pseudoContent')
  pseudo.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#bd-now'] }]
  expectAuditClean(boardAudit(pseudo))
  pseudo.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#unrelated'] }]
  assert.throws(() => expectAuditClean(boardAudit(pseudo)))
  const edges = audit('imgNode')
  edges.incomplete[0].nodes[0].any[0].relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['#bd-edges'] }]
  expectAuditClean(boardAudit(edges))
  // Future regression guard for the existing short-text/edge diagnostic.
  const short = structuredClone(edges)
  short.incomplete[0].nodes[0].any[0].data.messageKey = 'shortTextContent'
  expectAuditClean(boardAudit(short))
  short.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: ['#unrelated'] })
  assert.throws(() => expectAuditClean(boardAudit(short)))
  const image = structuredClone(edges)
  image.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: ['#unrelated-image'] })
  assert.throws(() => expectAuditClean(boardAudit(image)))
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

test('partial obscuring accepts only card-over-lane provenance', () => {
  const partial = audit('elmPartiallyObscured')
  partial.incomplete[0].nodes[0].target = ['div[title="Bugs"] > span']
  const check = partial.incomplete[0].nodes[0].any[0]
  check.relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['div[data-id="1260"] > .bd-in'] }]
  expectAuditClean(boardAudit(partial))
  for (const target of ['#unrelated', '.bd-in', 'div[data-id="1260"] > .unrelated']) {
    const extra = structuredClone(partial)
    extra.incomplete[0].nodes[0].any[0].relatedNodes.push({ target: [target] })
    assert.throws(() => expectAuditClean(boardAudit(extra)))
  }
  check.relatedNodes = [{ target: ['div[data-id="1260"] > .bd-in'] }]
  assert.throws(() => expectAuditClean(boardAudit(partial)))
  check.relatedNodes = [{ target: ['#bd-lanes'] }]
  assert.throws(() => expectAuditClean(boardAudit(partial)))
})


test('edge imgNode accepts card interiors and rejects unrelated related nodes', () => {
  const input = audit('imgNode')
  const check = input.incomplete[0].nodes[0].any[0]
  for (const card of ['div[data-id="607"] > .bd-in', 'div[data-id="607"] > .bd-in > .bd-top > .bd-id']) {
    check.relatedNodes = [{ target: ['#bd-edges'] }, { target: [card] }]
    expectAuditClean(boardAudit(input))
    check.relatedNodes.push({ target: ['#unrelated'] })
    assert.throws(() => expectAuditClean(boardAudit(input)))
  }
  for (const unrelated of ['.bd-in', 'div[data-id="607"] > .unrelated', '#bd-lanes']) {
    check.relatedNodes = [{ target: [unrelated] }]
    assert.throws(() => expectAuditClean(boardAudit(input)))
  }
})

// Explicit design baselines stay failures in the report and cannot absorb growth.
test('known contrast baselines reject worsening ratios, new elements and rules', async () => {
  const { recordContrastBaselines } = await import('../tests/support/build-home-contrast-baselines.mjs')
  const cell = { dataset: 'live', view: 'graph', theme: 'light' }
  const input = { violations: [{ id: 'color-contrast', nodes: [{ target: ['.promo'],
    any: [{ id: 'color-contrast', data: { contrastRatio: 4.14, messageKey: null } }], all: [], none: [] }] }], incomplete: [] }
  const measured = { 'div[data-id="607"] .bd-q.promo': { count: 1, ratio: 4.14, targets: ['.promo'] } }
  const result = recordContrastBaselines(input, cell, measured)
  expectAuditClean(result.audit)
  assert.equal(result.known[0].status, 'known baseline violation')
  assert.equal(result.known[0].followup, '#6292')
  assert.equal(input.violations[0].nodes.length, 1)
  assert.throws(() => recordContrastBaselines({ violations: [], incomplete: [] }, cell,
    { 'div[data-id="607"] .bd-q.promo': { count: 1, ratio: 4.10, targets: [] } }))
  for (const change of ['ratio', 'target', 'rule', 'duplicate']) {
    const bad = structuredClone(input)
    if (change === 'ratio') bad.violations[0].nodes[0].any[0].data.contrastRatio = 4.13
    if (change === 'target') bad.violations[0].nodes[0].target = ['.new-promotion']
    if (change === 'rule') bad.violations[0].id = 'new-rule'
    if (change === 'duplicate') bad.violations[0].nodes.push(structuredClone(bad.violations[0].nodes[0]))
    assert.throws(() => expectAuditClean(recordContrastBaselines(bad, cell, measured).audit))
  }
  assert.throws(() => recordContrastBaselines(input, cell, { 'div[data-id="607"] .bd-q.promo': { count: 2, ratio: 4.14, targets: ['.promo'] } }))
  assert.throws(() => expectAuditClean(recordContrastBaselines(input, { ...cell, theme: 'dark' }, measured).audit))
})

test('lane-count baseline accepts only the observed Design cell and rejects an unlisted lane', async () => {
  const { recordContrastBaselines } = await import('../tests/support/build-home-contrast-baselines.mjs')
  const cell = { dataset: 'dense', view: 'gantt', theme: 'dark', mode: 'read_only' }
  for (const title of ['Design', 'Bugs']) {
    const target = 'div[title="' + title + '"] > em'
    const input = { violations: [{ id: 'color-contrast', nodes: [{ target: [target],
      any: [{ id: 'color-contrast', data: { contrastRatio: 4.44 } }], all: [], none: [] }] }], incomplete: [] }
    const measured = { [target]: { count: 1, ratio: 4.3804, targets: [target] } }
    const result = recordContrastBaselines(input, cell, measured)
    if (title === 'Design') {
      expectAuditClean(result.audit)
      assert.deepEqual(result.known.map(entry => entry.id), ['lane-count:Design'])
      assert.throws(() => expectAuditClean(recordContrastBaselines(input, { ...cell, mode: 'writable' }, measured).audit))
    } else {
      assert.deepEqual(result.known, [])
      assert.throws(() => expectAuditClean(result.audit))
    }
  }
})

test('short-text baseline requires its measured ratio and exact node and cause', async () => {
  const { recordContrastBaselines } = await import('../tests/support/build-home-contrast-baselines.mjs')
  const target = 'span[title="openrouter"] > .ax-mono'
  const input = { violations: [], incomplete: [{ id: 'color-contrast', nodes: [{ target: [target],
    any: [{ id: 'color-contrast', data: { messageKey: 'shortTextContent' } }], all: [], none: [] }] }] }
  const measured = { [target]: { count: 1, ratio: 3.8174, targets: [target] } }
  const result = recordContrastBaselines(input, { dataset: 'unknowns' }, measured)
  expectAuditClean(result.audit)
  assert.equal(result.known[0].measuredRatio, 3.8174)
  assert.equal(result.known[0].followup, '#6293')
  assert.throws(() => recordContrastBaselines(input, { dataset: 'unknowns' }, { [target]: { ...measured[target], ratio: 3.81 } }))
  input.incomplete[0].nodes[0].any[0].data.messageKey = 'unknown-cause'
  assert.throws(() => expectAuditClean(recordContrastBaselines(input, { dataset: 'unknowns' }, measured).audit))
})

test('lane-icon background overlap requires the exact header-owned SVG', () => {
  const input = audit('imgNode')
  const check = input.incomplete[0].nodes[0].any[0]
  check.relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['#bd-lanes .bd-lx > svg'] }]
  expectAuditClean(boardAudit(input))
  for (const target of ['.bd-lx > svg', '#unrelated svg', '#bd-edges + svg']) {
    check.relatedNodes[1].target = [target]
    assert.throws(() => expectAuditClean(boardAudit(input)))
  }
})

test('card SVG over a lane requires both lane and card provenance', () => {
  const input = audit('imgNode')
  const check = input.incomplete[0].nodes[0].any[0]
  check.relatedNodes = [{ target: ['#bd-lanes'] }, { target: ['div[data-id="1286"] > .bd-in'] }]
  expectAuditClean(boardAudit(input))
  for (const target of ['#unrelated', '.bd-in', '#bd-lanes + svg']) {
    check.relatedNodes[1].target = [target]
    assert.throws(() => expectAuditClean(boardAudit(input)))
  }
  check.relatedNodes = [{ target: ['div[data-id="1286"] > .bd-in'] }]
  assert.throws(() => expectAuditClean(boardAudit(input)))
})
