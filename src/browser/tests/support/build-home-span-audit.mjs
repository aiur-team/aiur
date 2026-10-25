import { expectAuditClean } from './browser-helpers.mjs'

export function expectSpanAuditClean(audit) {
  // Axe cannot grade a lone U+2212 glyph. Span pixel/style parity checks its
  // rendered colours against the design; retain all violations and other incomplete nodes.
  for (const check of audit.incomplete) check.nodes = check.nodes.filter(node =>
    !(check.id === 'color-contrast' && node.target.join('') === 'button[data-z="1"]' && node.any.every(item => item.data?.messageKey === 'nonBmp')))
  expectAuditClean(audit)
}
