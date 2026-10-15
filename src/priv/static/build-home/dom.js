import { esc as escape } from './protocol.js';
export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
export const esc = value => escape(value == null ? '' : value);
