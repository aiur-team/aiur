/** Shared visual template for `<aiur-composer>`. */

export const TAG = 'aiur-composer';
export const BARS = 24;

const ICONS = {
  attach: '<path d="M12 5v14M5 12h14"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  voice: '<path d="M3 6.5A3.5 3.5 0 0 1 6.5 3h5A3.5 3.5 0 0 1 15 6.5v3a3.5 3.5 0 0 1-3.5 3.5H9l-3 2v-2.2A3.5 3.5 0 0 1 3 9.5z" fill="currentColor" stroke="none"/><path d="M10 14v1.5A3.5 3.5 0 0 0 13.5 19H15l3 2v-2.2a3.5 3.5 0 0 0 3-3.3v-3A3.5 3.5 0 0 0 17.5 9H17"/>',
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
  --_accent: var(--aiur-composer-accent, var(--aiur-color-accent, AccentColor));
  --_on-accent: var(--aiur-composer-on-accent, AccentColorText);
  --_focus: var(--aiur-composer-focus, var(--aiur-color-focus, AccentColor));
  --_radius: var(--aiur-composer-radius, var(--aiur-radius-xl, 24px));
  --_font: var(--aiur-composer-font, var(--aiur-font-body, system-ui, sans-serif));
  --_shadow: var(--aiur-composer-shadow, var(--aiur-shadow-md, 0 4px 16px rgb(0 0 0 / 0.12)));
  --_button: var(--aiur-composer-button-size, 44px);
  --_gap: var(--aiur-composer-gap, 6px);
  --_padding: var(--aiur-composer-padding, 6px);
  --_control-radius: var(--aiur-composer-control-radius, 999px);
  display: block;
  font-size: var(--aiur-composer-font-size, 1rem);
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
.card { display: grid; gap: var(--_gap); padding: var(--_padding); background: var(--_bg); border: 1px solid var(--_line); border-radius: var(--_radius); box-shadow: var(--_shadow); min-width: 0; }
.row { position: relative; display: flex; flex-wrap: nowrap; align-items: flex-end; gap: var(--_gap); min-width: 0; }
textarea { display: block; flex: 1 1 0; min-width: 0; min-height: var(--_button); max-height: var(--aiur-composer-max-input-height, 40vh); margin: 0; padding: 10px 4px; border: 0; outline: none; resize: none; overflow-y: auto; background: transparent; color: inherit; font: inherit; font-size: max(16px, 1em); line-height: 1.4; }
textarea::placeholder { color: var(--_muted); }
:host([data-recording]) textarea { padding-inline: 8px; }
.attachments { display: flex; flex-wrap: wrap; gap: var(--_gap); padding: 2px 2px 0; }
.attachments:empty { display: none; }
.chip { display: inline-flex; align-items: center; gap: 4px; max-width: 100%; padding: 2px 4px 2px 10px; border: 1px solid var(--_line); border-radius: var(--_control-radius); font-size: 0.85em; }
.chip[data-state="uploading"] { color: var(--_muted); }
.chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip button { width: 24px; height: 24px; flex: none; }
button { display: inline-grid; place-items: center; flex: none; width: var(--_button); height: var(--_button); padding: 0; border: 0; border-radius: var(--_control-radius); background: var(--_button-bg); color: inherit; cursor: pointer; touch-action: none; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
slot[hidden], .wave[hidden] { display: none; }
button:focus-visible { outline: 2px solid var(--_focus); outline-offset: 2px; }
button:disabled { cursor: default; opacity: 0.45; }
button[aria-pressed="true"] { background: var(--_accent); color: var(--_on-accent); }
button.send { background: var(--_accent); color: var(--_on-accent); }
svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
.chip svg { width: 14px; height: 14px; }
.wave { display: flex; flex: 1 1 0; min-width: 0; height: var(--_button); align-items: center; justify-content: center; gap: 3px; overflow: hidden; color: var(--_accent); }
.row > .wave { display: none; position: absolute; left: var(--_button); right: calc(var(--_button) * 2 + var(--_gap) * 2); top: calc(50% - var(--_button) / 2); }
.transcript { display: grid; gap: 4px; max-height: 30vh; overflow: auto; padding: 4px 8px; }
.transcript:empty { display: none; }
.transcript p { margin: 0; overflow-wrap: anywhere; }
.transcript [data-speaker="agent"] { text-align: right; }
slot[name="cancel"] { order: 1; }
slot[name="voice"] { order: 2; }
slot[name="mic"] { order: 3; }
slot[name="stop"] { order: 3; }
slot[name="send"] { order: 4; }
:host([data-dictation-state="recording"]) .row > .wave, :host([data-voice-state="live"]) .row > .wave { display: flex; }
:host([data-dictation-state="recording"]) slot[name="voice"] { animation: slide-in 160ms ease-out; }
@keyframes slide-in { from { opacity: 0; transform: translateX(8px); } to { opacity: 1; transform: translateX(0); } }
.wave i { flex: none; width: 3px; height: 28px; border-radius: 2px; background: currentColor; transform: scaleY(0.1); }
@media (prefers-reduced-motion: no-preference) { .wave i { transition: transform 80ms linear; } button[aria-pressed="true"] { animation: pulse 1.2s ease-in-out infinite; } }
@keyframes pulse { 50% { box-shadow: 0 0 0 6px color-mix(in srgb, var(--_accent) 25%, transparent); } }
slot[name="status"] { display: contents; }
[part="status"] { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
:host([data-error-code]) [part="status"] { position: static; width: auto; height: auto; clip-path: none; }
input[type="file"] { display: none; }
`;

function icon(name) {
  return `<svg part="${name}-icon" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

export const TEMPLATE = `
<style>${STYLE}</style>
<div class="card" part="card">
  <div class="attachments" part="attachments"></div>
  <div class="transcript" part="transcript" aria-live="polite"></div>
<div class="row" part="actions">
    <slot name="attach" hidden><button type="button" class="attach" part="attach" aria-label="Attach files">${icon('attach')}</button></slot>
    <slot name="input"><textarea part="input" rows="1" enterkeyhint="send"></textarea></slot>
    <slot name="cancel" hidden><button type="button" class="cancel" part="cancel" aria-label="Cancel dictation">${icon('cancel')}</button></slot>
    <span class="wave" part="waveform" aria-hidden="true" hidden>${'<i part="waveform-bar"></i>'.repeat(BARS)}</span>
    <slot name="voice" hidden><button type="button" class="voice" part="voice" aria-label="Switch to voice conversation" aria-pressed="false">${icon('voice')}</button></slot>
    <slot name="mic" hidden><button type="button" class="mic" part="mic" aria-label="Dictate">${icon('mic')}</button></slot>
    <slot name="stop" hidden><button type="button" class="stop" part="stop" aria-label="Stop dictation">${icon('stop')}</button></slot>
    <slot name="send"><button type="button" class="send" part="send" aria-label="Send" disabled>${icon('send')}</button></slot>
  </div>
  <slot name="status"><span role="status" part="status"></span></slot>
  <input part="file-input" type="file" multiple tabindex="-1" aria-hidden="true">
</div>
`;

export function iconMarkup(name) {
  return icon(name).replace('cancel-icon', 'remove-attachment-icon');
}
