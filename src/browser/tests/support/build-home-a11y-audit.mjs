// Kevin's preserve_visuals_revise_matrix decision: overlapping board layers
// prevent axe from sampling a background. Exempt only that diagnostic, never
// violations or other unknown causes. Token pairs are checked separately.
export function boardAudit(audit) {
  return {
    ...audit,
    incomplete: audit.incomplete.map(result => result.id !== 'color-contrast' ? result : {
      ...result,
      nodes: result.nodes.filter(node => {
        const checks = [...node.any, ...node.all, ...node.none]
        return !checks.length || !checks.every(check => check.data?.messageKey === 'bgOverlap')
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
