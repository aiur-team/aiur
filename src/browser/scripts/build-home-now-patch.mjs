import assert from 'node:assert/strict'

// The exporter and reference page apply identical bytes in memory; never edit the imported design.
export function nowPatch(source, dataset) {
  if (!['now0', 'now24'].includes(dataset)) return source
  const anchor = '    const PLAN = ['
  assert.equal(source.split(anchor).length, 2)
  const patch = dataset === 'now0' ? '    ACTIVE.length = 0;\n' :
    '    ACTIVE.push(...[1, 2].flatMap(copy => ACTIVE.slice(0, 8).map(row => [row[0] + "copy" + copy, ...row.slice(1)])));\n'
  return source.replace(anchor, patch + anchor)
}
