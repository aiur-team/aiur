// The package's ES modules, each behind a literal `import()` so a static reader
// — and the repository's component boundary guard — can resolve every file this
// package loads. `scripts/build.mjs` copies these modules into `dist/`, and
// `scripts/lint.mjs` imports each one and refuses a module in `src/` that is
// missing from this map, so a new module cannot ship without being listed.
export const MODULES = {
  'contract.js': () => import('../src/contract.js'),
  'element.js': () => import('../src/element.js'),
  'graph.js': () => import('../src/graph.js'),
  'html.js': () => import('../src/html.js'),
  'index.js': () => import('../src/index.js'),
  'parse.js': () => import('../src/parse.js'),
  'review.js': () => import('../src/review.js'),
  'styles.js': () => import('../src/styles.js'),
};
