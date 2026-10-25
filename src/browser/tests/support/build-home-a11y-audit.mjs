// Kevin's preserve_visuals_revise_matrix decision: overlapping board layers
// prevent axe from sampling a background. Exempt only that diagnostic, never
// violations or other unknown causes. Axe also calls the overlapping edge SVG
// an imgNode: require its exact related-node evidence, not that key alone.
// Token pairs are checked separately.
function overlapCheck(check) {
  if (check.data?.messageKey === 'bgOverlap') return true
  const key = check.data?.messageKey
  const related = (check.relatedNodes ?? []).map(node => node.target.join(''))
  if (key === 'pseudoContent') return related.length > 0 && related.every(target => target === '#bd-now')
  if (!['imgNode', 'shortTextContent'].includes(key)) return false
  const targets = (check.relatedNodes ?? []).map(node => node.target.join(''))
  return targets.includes('#bd-edges') && targets.every(target => ['#bd-edges', '#bd-lanes'].includes(target))
}
export function boardAudit(audit, measuredGlyphs = new Set()) {
  return {
    ...audit,
    incomplete: audit.incomplete.map(result => result.id !== 'color-contrast' ? result : {
      ...result,
      nodes: result.nodes.filter(node => {
        const checks = [...node.any, ...node.all, ...node.none]
        return !checks.length || !checks.every(check => overlapCheck(check) || (check.data?.messageKey === 'nonBmp' && measuredGlyphs.has(node.target.join(''))))
      })
    })
  }
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
