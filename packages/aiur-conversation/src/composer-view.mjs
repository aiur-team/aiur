/** Shared visual template for `<aiur-composer>`. */

export const TAG = 'aiur-composer';
export const BARS = 24;

const ICONS = {
  attach: '<path d="M12 5v14M5 12h14"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  voice: '<circle cx="7" cy="10" r="3"/><path d="M2 20a5 5 0 0 1 10 0"/><circle cx="17" cy="10" r="3"/><path d="M12 20a5 5 0 0 1 10 0M10 4.5q2-2 4 0"/>',
  send: '<path d="M12 19V5M6 11l6-6 6 6"/>',
  cancel: '<path d="M6 6l12 12M18 6L6 18"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor"/>',
};

const STYLE = `
:host {
  --_bg: var(--aiur-composer-bg, var(--aiur-color-surface, #ffffff));
  --_fg: var(--aiur-composer-fg, var(--aiur-color-fg, #1c2128));
  --_muted: var(--aiur-composer-muted, var(--aiur-color-muted, #58606a));
  --_line: var(--aiur-composer-line, var(--aiur-color-line, #d0d7de));
  --_button-bg: var(--aiur-composer-button-bg, var(--aiur-color-surface-2, #eef1f4));
  --_accent: var(--aiur-composer-accent, var(--aiur-color-accent, #2457d6));
  --_on-accent: var(--aiur-composer-on-accent, #ffffff);
  --_focus: var(--aiur-composer-focus, var(--aiur-color-focus, #2457d6));
  --_radius: var(--aiur-composer-radius, var(--aiur-radius-xl, 24px));
  --_font: var(--aiur-composer-font, var(--aiur-font-body, system-ui, sans-serif));
  --_shadow: var(--aiur-composer-shadow, var(--aiur-shadow-md, 0 4px 16px rgb(0 0 0 / 0.12)));
  --_button: var(--aiur-composer-button-size, 44px);
  display: block;
  box-sizing: border-box;
  font-family: var(--_font);
  color: var(--_fg);
}
:host([hidden]) { display: none; }
:host([pinned]) {
  position: fixed;
  left: 0;
  right: 0;
  bottom: var(--aiur-composer-keyboard-inset, 0px);
  z-index: var(--aiur-composer-z, 10);
  padding: 8px max(8px, env(safe-area-inset-right)) max(8px, env(safe-area-inset-bottom)) max(8px, env(safe-area-inset-left));
}
*, *::before, *::after { box-sizing: border-box; }
.card { display: grid; gap: 6px; padding: 6px; background: var(--_bg); border: 1px solid var(--_line); border-radius: var(--_radius); box-shadow: var(--_shadow); min-width: 0; }
.row { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 6px; min-width: 0; }
textarea { display: block; flex: 1 1 0; min-width: 0; min-height: var(--_button); max-height: var(--aiur-composer-max-input-height, 40vh); margin: 0; padding: 10px 4px; border: 0; outline: none; resize: none; overflow-y: auto; background: transparent; color: inherit; font: inherit; font-size: max(16px, 1em); line-height: 1.4; }
textarea::placeholder { color: var(--_muted); }
:host([data-recording]) textarea { flex-basis: 100%; padding-inline: 8px; }
.attachments { display: flex; flex-wrap: wrap; gap: 6px; padding: 2px 2px 0; }
.attachments:empty { display: none; }
.chip { display: inline-flex; align-items: center; gap: 4px; max-width: 100%; padding: 2px 4px 2px 10px; border: 1px solid var(--_line); border-radius: 999px; font-size: 0.85em; }
.chip[data-state="uploading"] { color: var(--_muted); }
.chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip button { width: 24px; height: 24px; flex: none; }
button { display: inline-grid; place-items: center; flex: none; width: var(--_button); height: var(--_button); padding: 0; border: 0; border-radius: 999px; background: var(--_button-bg); color: inherit; cursor: pointer; touch-action: none; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
button[hidden], .wave[hidden] { display: none; }
button:focus-visible { outline: 2px solid var(--_focus); outline-offset: 2px; }
button:disabled { cursor: default; opacity: 0.45; }
button[aria-pressed="true"] { background: var(--_accent); color: var(--_on-accent); }
button.send { background: var(--_accent); color: var(--_on-accent); }
svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
.chip svg { width: 14px; height: 14px; }
.wave { display: flex; flex: 1 1 0; min-width: 0; height: var(--_button); align-items: center; justify-content: center; gap: 3px; overflow: hidden; color: var(--_accent); }
.wave i { flex: none; width: 3px; height: 28px; border-radius: 2px; background: currentColor; transform: scaleY(0.1); }
@media (prefers-reduced-motion: no-preference) { .wave i { transition: transform 80ms linear; } button[aria-pressed="true"] { animation: pulse 1.2s ease-in-out infinite; } }
@keyframes pulse { 50% { box-shadow: 0 0 0 6px color-mix(in srgb, var(--_accent) 25%, transparent); } }
input[type="file"] { display: none; }
`;

function icon(name) {
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

export const TEMPLATE = `
<style>${STYLE}</style>
<div class="card" part="card">
  <div class="attachments" part="attachments"></div>
  <div class="row" part="actions">
    <button type="button" class="attach" part="attach" aria-label="Attach files" hidden>${icon('attach')}</button>
    <textarea part="input" rows="1" enterkeyhint="send"></textarea>
    <button type="button" class="cancel" part="cancel" aria-label="Cancel dictation" hidden>${icon('cancel')}</button>
    <span class="wave" part="waveform" aria-hidden="true" hidden>${'<i></i>'.repeat(BARS)}</span>
    <button type="button" class="mic" part="mic" aria-label="Dictate" hidden>${icon('mic')}</button>
    <button type="button" class="voice" part="voice" aria-label="Switch to voice conversation" aria-pressed="false" hidden>${icon('voice')}</button>
    <button type="button" class="stop" part="stop" aria-label="Stop dictation" hidden>${icon('stop')}</button>
    <button type="button" class="send" part="send" aria-label="Send" disabled>${icon('send')}</button>
  </div>
  <input type="file" multiple tabindex="-1" aria-hidden="true">
</div>
`;

export function iconMarkup(name) {
  return icon(name);
}
