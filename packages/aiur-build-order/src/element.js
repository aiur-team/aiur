import { ELEMENT_NAME } from './contract.js';
import { renderGraph } from './graph.js';
import { escapeHtml } from './html.js';
import { parseBuildOrder } from './parse.js';
import { renderReview } from './review.js';
import { STYLES } from './styles.js';

// Node has no HTMLElement, and a subclass declaration must not throw there:
// the renderers and the parser are importable without a DOM.
const HTMLElementBase = typeof globalThis.HTMLElement === 'function' ? globalThis.HTMLElement : class {};

const VIEWS = ['review', 'graph', 'both'];

/**
 * `<aiur-build-order>` mounts the review, the graph, or both from one document.
 *
 * Sources, in order: the `json` attribute or `json` property, then a `fetch`
 * function property, then the `src` URL. `view` is `review`, `graph` or `both`.
 * A parse or fetch failure renders the structured error instead of a blank box
 * and is readable from `element.error`.
 */
export class AiurBuildOrderElement extends HTMLElementBase {
  static get observedAttributes() {
    return ['src', 'json', 'view'];
  }

  #input = null;
  #fetchFunction = null;
  #document = null;
  #error = null;
  #request = 0;

  connectedCallback() {
    injectStyles(this.ownerDocument);
    this.load();
  }

  disconnectedCallback() {
    this.#request += 1;
  }

  attributeChangedCallback(name) {
    if (name === 'json') this.#input = null;
    if (name === 'view') {
      if (this.isConnected) this.render();
      return;
    }
    if (this.isConnected) this.load();
  }

  /** An object, a JSON string, or null to fall back to `src`. */
  get json() {
    return this.#input ?? this.getAttribute('json');
  }

  set json(value) {
    this.#input = value;
    if (this.isConnected) this.load();
  }

  /** A fetch-compatible function used instead of the page's global fetch. */
  get fetch() {
    return this.#fetchFunction;
  }

  set fetch(value) {
    this.#fetchFunction = typeof value === 'function' ? value : null;
    if (this.isConnected) this.load();
  }

  get view() {
    const view = (this.getAttribute('view') ?? '').toLowerCase();
    return VIEWS.includes(view) ? view : 'both';
  }

  get document() {
    return this.#document;
  }

  get error() {
    return this.#error;
  }

  /** Resolve the current source, parse it and render. Safe to call directly. */
  async load() {
    const request = (this.#request += 1);
    const input = this.json ?? null;
    let source = input;

    if (source === null && this.hasAttribute('src')) {
      const read = await this.#readSource(this.getAttribute('src') ?? '');
      if (request !== this.#request) return;
      if (!read.ok) {
        this.#fail(read.error);
        return;
      }
      source = read.value;
    }

    if (source === null) {
      this.#fail({ code: 'missing_source', message: 'Set a json attribute, a src URL or a fetch function.', path: [] });
      return;
    }

    const parsed = parseBuildOrder(source);
    if (request !== this.#request) return;
    if (!parsed.ok) {
      this.#fail(parsed.error);
      return;
    }

    this.#document = parsed.document;
    this.#error = null;
    this.render();
    this.dispatchEvent(new CustomEvent('aiur-build-order:load', { bubbles: true, composed: true, detail: { document: this.#document } }));
  }

  render() {
    if (!this.ownerDocument) return;
    if (this.#error) {
      this.dataset.status = 'error';
      this.innerHTML = errorMarkup(this.#error);
      return;
    }
    if (!this.#document) {
      this.dataset.status = 'empty';
      this.innerHTML = '<div class="aiur-bo" data-status="empty"><p class="aiur-bo-note">No build order loaded yet.</p></div>';
      return;
    }

    const view = this.view;
    const document_ = this.#document;
    const parts = [];
    if (view === 'review' || view === 'both') parts.push(renderReview(document_));
    if (view === 'graph' || view === 'both') parts.push(renderGraph(document_));
    this.dataset.status = document_.status;
    this.innerHTML = parts.join('\n');
  }

  async #readSource(url) {
    const fetcher = this.#fetchFunction ?? globalThis.fetch;
    if (typeof fetcher !== 'function' || url === '') {
      return { ok: false, error: { code: 'fetch_failed', message: `No fetch function is available to load ${url || 'the source'}.`, path: [] } };
    }
    try {
      const response = await fetcher(url, { headers: { accept: 'application/json' } });
      if (response && response.ok === false) {
        return { ok: false, error: { code: 'fetch_failed', message: `GET ${url} returned ${response.status ?? 'an error'}.`, path: [] } };
      }
      if (response && typeof response.text === 'function') return { ok: true, value: await response.text() };
      return { ok: true, value: response };
    } catch (error) {
      return { ok: false, error: { code: 'fetch_failed', message: `GET ${url} failed: ${error.message}`, path: [] } };
    }
  }

  #fail(error) {
    this.#document = null;
    this.#error = error;
    this.render();
    this.dispatchEvent(new CustomEvent('aiur-build-order:error', { bubbles: true, composed: true, detail: { error } }));
  }
}

function errorMarkup(error) {
  const path = Array.isArray(error.path) && error.path.length > 0 ? `<p class="aiur-bo-note">${escapeHtml(error.path.join('.'))}</p>` : '';
  return `<div class="aiur-bo" data-status="error"><div class="aiur-bo-banner" role="alert">
<p class="aiur-bo-banner-head">This build order could not be read</p>
<p class="aiur-bo-banner-body">${escapeHtml(error.message)}</p>
${path}
</div></div>`;
}

function injectStyles(document_) {
  const head = document_?.head;
  if (!head || head.querySelector('style[data-aiur-build-order]')) return;
  const style = document_.createElement('style');
  style.setAttribute('data-aiur-build-order', '');
  style.textContent = STYLES;
  head.appendChild(style);
}

/** Define the element once. Returns true when this call defined it. */
export function registerAiurBuildOrder(registry = globalThis.customElements) {
  if (!registry || typeof registry.define !== 'function' || registry.get(ELEMENT_NAME)) return false;
  registry.define(ELEMENT_NAME, AiurBuildOrderElement);
  return true;
}

if (typeof globalThis.customElements !== 'undefined') registerAiurBuildOrder();
