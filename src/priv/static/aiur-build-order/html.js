const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

/** Escape text for an HTML or SVG text node and for a quoted attribute value. */
export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ENTITIES[character]);
}

/** A dash for anything a reader would otherwise see as blank. */
export function orDash(value) {
  if (value === null || value === undefined || value === '') return '—';
  return String(value);
}

/** Shorten a label without cutting a word in half when a space is available. */
export function truncate(value, limit) {
  const text = String(value ?? '');
  if (text.length <= limit) return text;
  const clipped = text.slice(0, limit - 1);
  const space = clipped.lastIndexOf(' ');
  return `${(space > limit / 2 ? clipped.slice(0, space) : clipped).trimEnd()}…`;
}

/** Percent text for a known bar, or a dash when the source did not report one. */
export function percentText(percent) {
  return Number.isFinite(percent) ? `${percent}%` : '—';
}

/**
 * A link target the renderers will publish, or null.
 *
 * The document is written by a publisher the page trusts, but a link is the one
 * place a document reaches out of the page, so only absolute http(s) URLs and
 * site-relative paths become an `href`.
 */
export function safeUrl(value) {
  if (typeof value !== 'string') return null;
  const url = value.trim();
  if (url === '') return null;
  if (url.startsWith('/') || url.startsWith('#')) return url;
  return /^https?:\/\//i.test(url) ? url : null;
}

/** A count, or a dash when the document carries none. */
export function countText(count) {
  return Number.isFinite(count) ? String(count) : '—';
}

/** ISO timestamp trimmed to minutes, or a dash when the document carries none. */
export function stampText(value) {
  if (typeof value !== 'string' || value === '') return '—';
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return value;
  return new Date(parsed).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
}
