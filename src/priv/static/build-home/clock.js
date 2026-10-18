import { onReset } from './state.js';
let ms = null, at = null;
export const stampMs = () => ms;
onReset(() => { ms = null; at = null; });
export function setNow(value) { ms = value; at = performance.now(); }
export const nowMs = () => ms === null ? null : ms + (performance.now() - at);
