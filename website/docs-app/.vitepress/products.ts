// The three products the docs cover. Shared by the site config (per-product
// locales, nav and sidebars) and the ProductSwitcher theme component, so the
// dropdown and the routes it points at cannot drift apart.

export interface Product {
  id: 'aiur' | 'archon' | 'khala'
  /** Display name in the switcher menu. */
  name: string
  /** Wordmark shown in the nav bar, set in Bungee like aiur.team. */
  wordmark: string
  /** Path prefix under the docs base; Aiur owns every other path. */
  prefix: string
  /** Where choosing the product in the switcher navigates to. */
  root: string
  /** Image logo from the product's live site, or null for a monogram mark. */
  logo: string | null
  /** One-line description shown under the name in the menu. */
  blurb: string
}

export const products: Product[] = [
  {
    id: 'aiur',
    name: 'Aiur',
    wordmark: 'AIUR',
    prefix: '/',
    root: '/',
    logo: '/assets/aiur-logo.png',
    blurb: 'Coordinate fleets of coding agents'
  },
  {
    id: 'archon',
    name: 'Archon',
    wordmark: 'ARCHON',
    prefix: '/archon/',
    root: '/archon/quick-start',
    // archon.aiur.team serves this same image (site/assets/aiur-logo.png in
    // aiur-team/archon) beside its ARCHON wordmark.
    logo: '/assets/aiur-logo.png',
    blurb: 'Always-on architecture docs'
  },
  {
    id: 'khala',
    name: 'Khala',
    wordmark: 'KHALA',
    prefix: '/khala/',
    root: '/khala/quick-start',
    // Khala has no brand asset yet (apps/web/src/brand/SOURCES.md in
    // aiur-team/khala), so the switcher draws a monogram instead.
    logo: null,
    blurb: 'Encrypted chat between agents'
  }
]

/** The product a page belongs to, from its path relative to the docs root. */
export function productForPath(relativePath: string): Product {
  const path = '/' + relativePath.replace(/^\//, '')
  return products.find((p) => p.prefix !== '/' && path.startsWith(p.prefix)) ?? products[0]
}
