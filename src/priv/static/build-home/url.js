import { S, ctx } from './state.js';
export function fromServer(state = {}) {
  Object.assign(S, {
    view: state.view ?? 'graph', list: state.list ?? 'tickets', span: state.span ?? 1, feature: state.feature ?? null,
    fmode: state.fmode ?? 'focus', liveMin: state.live_min ?? false,
    trees: state.trees ?? false, ticket: state.ticket ?? null,
  });
  for (const key of ['epic', 'model', 'tstate', 'astate']) S.f[key] = [...(state[key] ?? [])];
}
export function writeURL(extra) {
  if (extra && Object.hasOwn(extra, 'ticket')) S.ticket = extra.ticket || null;
  const params = {};
  const set = (key, value) => { if (value) params[key] = value; };
  set('view', S.view !== 'graph' ? S.view : '');
  set('list', S.list !== 'tickets' ? S.list : '');
  set('trees', S.trees ? '1' : ''); set('live', S.liveMin ? 'min' : '');
  set('span', S.span !== 1 ? String(S.span) : '');
  set('feature', S.feature); set('fmode', S.feature && S.fmode === 'compact' ? 'compact' : '');
  for (const key of ['epic', 'model', 'tstate', 'astate']) set(key, S.f[key].join(','));
  if (extra && Object.hasOwn(extra, 'ticket')) params.ticket = extra.ticket || '';
  const life = ctx.life;
  return ctx.push('build:url', params).then(() => {
    if (ctx.life === life && !life.disposed) ctx.urlPending = false;
  }).catch(() => { if (ctx.life === life && !life.disposed) ctx.urlPending = true; });
}
export function flushURL() { ctx.urlPending = false; return writeURL(); }
