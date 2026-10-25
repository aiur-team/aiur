import config from './playwright.design-parity.config.mjs'

const full = process.env.AIUR_PARITY_FULL === '1'

export default {
  ...config,
  // Routine CI exercises every sequence; the complete product matrix is the sign-off run.
  grep: full ? /.*/ : /^.* (?:clock probe:|harness self-check:|design determinism:).+$/,
  fullyParallel: full ? config.fullyParallel : true,
  workers: full ? config.workers : 2
}
