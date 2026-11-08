import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));

/** Read a committed fixture as text, the way a consumer would fetch it. */
export function fixtureText(name) {
  return readFileSync(new URL(`../fixtures/${name}`, import.meta.url), 'utf8');
}

/** Read a committed fixture as a plain object. */
export function fixture(name) {
  return JSON.parse(fixtureText(name));
}

export const fixturePath = (name) => `${here}../fixtures/${name}`;

/** A shallow copy of the reference fixture, for tests that change one top-level field. */
export function documentWith(overrides) {
  return { ...fixture('build-order.v1.json'), ...overrides };
}

/** A shallow copy whose first ticket is replaced, for per-ticket checks. */
export function ticketWith(overrides) {
  const base = fixture('build-order.v1.json');
  return { ...base, tickets: [{ ...base.tickets[0], ...overrides }, ...base.tickets.slice(1)] };
}
