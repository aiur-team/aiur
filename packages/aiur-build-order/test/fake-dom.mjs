import { AiurBuildOrderElement } from '../src/index.js';

/**
 * A custom element in a page it can touch, without a browser.
 *
 * Node has no `HTMLElement`, so the element's base is a plain class and the
 * handful of DOM members it reads can be supplied per instance. This exercises
 * source resolution, parsing, rendering and the events, which is everything the
 * element does before a real Chromium run (see `test/browser/`).
 */
export function mount(attributes = {}) {
  const element = new AiurBuildOrderElement();
  const events = [];
  const head = { children: [], querySelector: () => null, appendChild(child) { head.children.push(child); } };
  const document_ = { head, createElement: () => ({ setAttribute() {}, textContent: '' }) };
  const values = new Map(Object.entries(attributes));

  Object.assign(element, {
    ownerDocument: document_,
    dataset: {},
    innerHTML: '',
    isConnected: true,
    getAttribute: (name) => (values.has(name) ? values.get(name) : null),
    setAttribute: (name, value) => { values.set(name, String(value)); },
    hasAttribute: (name) => values.has(name),
    removeAttribute: (name) => { values.delete(name); },
    dispatchEvent: (event) => { events.push(event); return true; },
  });

  return { element, events, head, values };
}

/** Let the element's async load settle. */
export const settle = () => new Promise((resolve) => setImmediate(resolve));
