import test from 'node:test';
import assert from 'node:assert/strict';
import { EVK, evHue, eventHTML } from '../../priv/static/build-home/modal/conversation-events.js';
import { cursorOf } from '../../priv/static/build-home/modal/conversation-items.js';
import { I, MI } from '../../priv/static/build-home/icons.js';

// Event rows are the operator's record of what happened to a ticket: each kind must be the design's row
// (J:1284, J:1341–1352), and an unknown time or percent must stay visibly unknown instead of turning into
// a real-looking value. Runs under TZ=America/Los_Angeles (package.json).
const DESIGN_EVK = { dep: [190, 'link'], commit: [255, 'commit'], prog: [null, 'prog'], pr: [300, 'pr'], review: [85, 'review'], comment: [220, 'chat'], merge: [150, 'merge'], fail: [25, 'warn'], cmd: [25, 'warn'], you: [0, 'pause'] };
const AT = 1791407600000;
const row = (ev, extra = {}) => ({ id: 'ev:' + ev, k: 'ev', ev, label: ev + ' label', at: AT, ...(ev === 'prog' ? { pct: 50 } : {}), ...extra });
const attr = (html, name) => (new RegExp(' ' + name + '="([^"]*)"').exec(html) || [])[1];
const text = (html, tag) => (new RegExp('<' + tag + '[^>]*>([^<]*)</' + tag + '>').exec(html) || [])[1];

test('B1 every kind renders the design row: class, hue, icon and data attributes', () => {
  assert.deepEqual(EVK, DESIGN_EVK);
  for (const [ev, [hue, icon]] of Object.entries(DESIGN_EVK)) {
    const html = eventHTML(row(ev, ev === 'dep' ? { go: '597', sub: 'Dependency title', label: 'Dependency #597 merged' } : {}));
    assert.equal(attr(html, 'class'), 'cv-ev' + (['fail', 'cmd'].includes(ev) ? ' bad' : ev === 'you' ? ' mute' : ''), ev);
    assert.equal(attr(html, 'style'), '--eh:' + (ev === 'prog' ? 94 : hue), ev);
    assert.ok(html.includes('<span class="cv-evi">' + (I[icon] || MI[icon]).replace('<svg ', '<svg aria-hidden="true" ') + '</span>'), ev);
    assert.equal(attr(html, 'data-k'), 'ev'); assert.equal(attr(html, 'data-ev'), ev); assert.equal(attr(html, 'data-at'), '14:13');
    assert.equal(html.includes('class="cv-go"'), ev === 'dep', ev);
  }
  const dep = eventHTML(row('dep', { go: '597', sub: 'Dependency title', label: 'Dependency #597 merged' }));
  assert.equal(attr(dep, 'data-goto'), '597');
  assert.equal(attr(dep, 'aria-label'), 'Open #597 Dependency title');
  assert.equal(text(dep, 'button'), 'Open');
  assert.equal(evHue({ ev: 'prog', pct: 0 }), 42);
});

test('B2 an unknown time is a dash, never a clock reading', () => {
  const html = eventHTML(row('pr', { at: null }));
  assert.equal(text(html, 'time'), '—');
  assert.match(html, /<time title="Time unknown">/);
  assert.doesNotMatch(html, /datetime=/);
  assert.equal(attr(html, 'data-at'), '—');
});

test('B3 an unknown percent is muted, never the 0% hue', () => {
  const html = eventHTML({ id: 'ev:log:1', k: 'ev', ev: 'prog', label: 'Progress updated', at: AT });
  assert.equal(attr(html, 'class'), 'cv-ev mute');
  assert.equal(attr(html, 'style'), undefined);
  assert.equal(text(html, 'b'), 'Progress updated');
});

test('B5 hostile label, sub and go stay text', () => {
  const hostile = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=1</script>';
  const html = eventHTML(row('dep', { label: hostile, sub: hostile, go: '"><img src=x>' }));
  assert.doesNotMatch(html, /<img|<script/);
  assert.equal(attr(html, 'data-goto'), '&quot;&gt;&lt;img src=x&gt;');
});

test('B6 times are local, across the DST change', () => {
  const a = eventHTML(row('pr', { at: Date.parse('2026-11-01T08:30:00Z') })), b = eventHTML(row('pr', { at: Date.parse('2026-11-01T09:30:00Z') }));
  assert.equal(text(eventHTML(row('pr')), 'time'), '14:13');
  assert.equal(text(a, 'time'), '01:30'); assert.equal(text(b, 'time'), '01:30');
  assert.notEqual(attr(a, 'datetime'), attr(b, 'datetime'));
});

test('B7 a merge row with no sub shows its local date and time; unknown time shows no sub', () => {
  assert.match(eventHTML(row('merge', { label: 'Merged PR #8' })), /<span class="cv-evs">Oct 7 14:13<\/span>/);
  assert.doesNotMatch(eventHTML(row('merge', { at: null })), /cv-evs/);
});

test('server event rows, including their sys rows, are never page cursors', () => {
  assert.equal(cursorOf({ id: 'ev:sys:unreadable', k: 'sys' }), null);
  assert.equal(cursorOf({ id: 'ev:log:4', k: 'ev' }), null);
  assert.equal(cursorOf({ id: 'f:3', k: 'say' }), 'f:3');
  assert.equal(cursorOf({ id: 'answer:1', k: 'op', cursor: 'f:9' }), 'f:9');
});
