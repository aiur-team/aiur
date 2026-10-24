import { ctx, onReset } from '../state.js';
import { MI } from '../icons.js';

export const controlBodies = Object.create(null);
const bodies = controlBodies;
let generation = 0;
export function resetControls() { generation++; Object.keys(bodies).forEach(id => delete bodies[id]); }
onReset(resetControls);

export function applyControl(head, t, ctl = bodies[t.id]) {
  const group = head.querySelector('.bm-agent');
  if (!group) return;
  if (ctl) group.dataset.control = 'ready'; else delete group.dataset.control;
  const pause = group.querySelector('[data-a="pause"]'), chat = group.querySelector('[data-a="chat"]');
  if (pause) {
    const control = ctl?.control, disabled = control?.state !== 'enabled';
    const title = control?.title || (ctl ? 'Agent control unavailable' : 'Checking agent control…');
    pause.removeAttribute('disabled'); pause.title = title; pause.setAttribute('aria-label', title);
    if (disabled) pause.setAttribute('aria-disabled', 'true'); else pause.removeAttribute('aria-disabled');
    if (control?.state === 'pending') pause.setAttribute('aria-busy', 'true'); else pause.removeAttribute('aria-busy');
    pause.classList.toggle('bad', control?.status?.tone === 'error');
    pause.classList.toggle('warn', control?.status?.tone === 'warning');
    const action = ['enabled', 'pending'].includes(control?.state) ? control.action : t.agent?.state === 'paused' ? 'resume' : 'pause';
    pause.innerHTML = action === 'resume' ? MI.play : MI.pause;
  }
  if (chat) {
    chat.removeAttribute('disabled'); chat.hidden = !ctl?.chat; chat.style.display = chat.hidden ? 'none' : '';
    chat.title = 'Open in Conversations'; chat.setAttribute('aria-label', chat.title);
  }
  let status = group.querySelector('[role="status"]');
  if (!status) {
    status = document.createElement('span'); status.className = 'sr-only';
    status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite'); status.setAttribute('aria-atomic', 'true');
    group.append(status);
  }
  status.textContent = ctl?.control?.status?.label || '';
}

export function receiveControl(head, t, body) {
  if (body?.v !== 1 || body.kind !== 'control' || typeof body.id !== 'string') return;
  bodies[body.id] = body;
  if (t?.id === body.id) applyControl(head, t, body);
}

export function wireAgentControl(head, ticket) {
  ctx.life.on(head, 'click', async event => {
    const button = event.target.closest('[data-a="pause"], [data-a="chat"]'), t = ticket();
    if (!button || !t || button.hidden || button.getAttribute('aria-disabled') === 'true') return;
    const chat = button.dataset.a === 'chat', body = bodies[t.id], current = generation, life = ctx.life;
    if (ctx.socket !== 'up') { fail(button, chat, 'unavailable'); return; }
    const action = body?.control?.action;
    if (!chat && !['pause', 'resume'].includes(action)) return;
    let reply;
    try { reply = await ctx.push(chat ? 'open-conversation' : 'request-unit-control', chat ? { id: t.id } : { id: t.id, action }); }
    catch { reply = { kind: 'error', reason: 'unavailable' }; }
    if (generation !== current || life !== ctx.life || life.disposed || ticket()?.id !== t.id) return;
    if (reply?.kind === 'control') receiveControl(head, t, reply);
    else if (reply?.kind === 'error') fail(head.querySelector('[data-a="' + (chat ? 'chat' : 'pause') + '"]'), chat, reply.reason);
  });
}

function fail(button, chat, reason) {
  if (!button) return;
  const titles = { read_only: 'Dashboard is read-only', unavailable: 'Agent control unavailable', invalid_params: 'Control unavailable' };
  button.title = chat ? 'Chat is unavailable for this ticket.' : titles[reason] || titles.unavailable;
  button.setAttribute('aria-label', button.title); button.classList.add('bad');
}
