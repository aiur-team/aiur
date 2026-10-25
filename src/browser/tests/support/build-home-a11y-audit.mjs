// Kevin's preserve_visuals_revise_matrix decision: overlapping board layers
// prevent axe from sampling a background. Exempt only that diagnostic, never
// violations or other unknown causes. Axe also calls the overlapping edge SVG
// an imgNode: require its exact related-node evidence, not that key alone.
// Token pairs are checked separately.
function overlapCheck(check) {
  if (check.data?.messageKey === 'bgOverlap') return true
  const key = check.data?.messageKey
  const related = (check.relatedNodes ?? []).map(node => node.target.join(''))
  if (key === 'elmPartiallyObscured') {
    const card = target => /^div\[data-id="[^"]+"\] > \.bd-in$/.test(target)
    return related.includes('#bd-lanes') && related.some(card) && related.every(target => target === '#bd-lanes' || card(target))
  }
  if (key === 'pseudoContent') return related.length > 0 && related.every(target => target === '#bd-now')
  if (!['imgNode', 'shortTextContent'].includes(key)) return false
  const targets = (check.relatedNodes ?? []).map(node => node.target.join(''))
  const card = target => /^div\[data-id="[^"]+"\] > \.bd-in(?: > [\w.#:[\]=" -]+)*$/.test(target)
  return targets.includes('#bd-edges') && targets.every(target => ['#bd-edges', '#bd-lanes'].includes(target) || (key === 'imgNode' && card(target)))
}
export function boardAudit(audit) {
  return {
    ...audit,
    incomplete: audit.incomplete.map(result => result.id !== 'color-contrast' ? result : {
      ...result,
      nodes: result.nodes.filter(node => {
        const checks = [...node.any, ...node.all, ...node.none]
        return !checks.length || !checks.every(overlapCheck)
      })
    })
  }
}

// Axe may address the same card interior by title instead of by its data-id.
// Resolve that selector against the actual DOM before applying the narrow rule.
export async function canonicalBoardOverlaps(page, audit) {
  const result = structuredClone(audit)
  const checks = result.incomplete.filter(rule => rule.id === 'color-contrast')
    .flatMap(rule => rule.nodes).flatMap(node => [...node.any, ...node.all, ...node.none])
  const related = checks.filter(check => ['imgNode', 'elmPartiallyObscured'].includes(check.data?.messageKey))
    .flatMap(check => check.relatedNodes ?? []).filter(node => node.target.length === 1)
  const mapping = await page.evaluate(selectors => Object.fromEntries(selectors.map(selector => {
    const nodes = document.querySelectorAll(selector)
    const node = nodes.length === 1 ? nodes[0] : null
    const interior = node?.closest('.bd-in')
    const card = interior?.parentElement
    return [selector, card?.matches('.bd-card[data-id]') ?
      'div[data-id=' + JSON.stringify(card.dataset.id) + '] > .bd-in' : null]
  })), [...new Set(related.map(node => node.target[0]))])
  for (const node of related) if (mapping[node.target[0]]) node.target = [mapping[node.target[0]]]
  return result
}

export function contrastRatio(foreground, background) {
  const luminance = hex => {
    if (!/^#[\da-f]{6}$/i.test(hex)) throw new Error(`Expected an opaque sRGB token, received ${hex}`)
    const channels = [1, 3, 5].map(offset => parseInt(hex.slice(offset, offset + 2), 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
  }
  const values = [luminance(foreground), luminance(background)].sort((a, b) => a - b)
  return (values[1] + 0.05) / (values[0] + 0.05)
}
