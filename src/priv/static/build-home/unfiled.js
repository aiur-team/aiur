// Shared display rules for planning-pack rows, including their pre-filing identity.
export const isUnfiled = t => t?.num == null && (t?.src?.kind === 'pack' ||
  (t?.src == null && typeof t?.id === 'string' && t.id.startsWith('pack:')));
export const refText = t => isUnfiled(t) ? '—' : '#' + (Number.isFinite(t.num) ? t.num : '—');
export const refTitle = t => isUnfiled(t) ? 'Not filed yet' : Number.isFinite(t.num) ? refText(t) : 'Ticket number unknown';
export const queueText = t => isUnfiled(t) ? 'Not filed' : t.qpos == null ? 'Q?' : 'Q' + (Number.isFinite(t.qpos) ? t.qpos : '—');
export const srcLine = t => (t.src?.path || 'Source unknown') + (t.src?.wave != null ? ' · wave ' + t.src.wave : '') + ' · not filed yet';
export const srcTitle = t => t.src?.path ? 'From ' + t.src.path + (t.src.wave != null ? ' · wave ' + t.src.wave : '') : 'Source unknown';
export const findWas = (rows, id) => rows.find(row => row.was === id) || null;
