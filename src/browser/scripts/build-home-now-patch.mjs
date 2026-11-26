import assert from 'node:assert/strict'

// The exporter and reference page apply identical bytes in memory; never edit the imported design.
// Review adopted a lower-bound cue while running work is excluded from ETA hours.
export function estimatePatch(source) {
  const anchor = '(D.plan.length ? Math.round(D.plan.reduce'
  assert.equal(source.split(anchor).length, 2)
  return source.replace(anchor, '(D.plan.length ? (D.now.length ? "≥" : "") + Math.round(D.plan.reduce')
}
export function nowPatch(source, dataset) {
  source = estimatePatch(source)
  if (!['now0', 'now24'].includes(dataset)) return source
  const anchor = '    const PLAN = ['
  assert.equal(source.split(anchor).length, 2)
  const patch = dataset === 'now0' ? '    ACTIVE.length = 0;\n' :
    '    ACTIVE.push(...[1, 2].flatMap(copy => ACTIVE.slice(0, 8).map(row => [row[0] + "copy" + copy, ...row.slice(1)])));\n'
  return source.replace(anchor, patch + anchor)
}
