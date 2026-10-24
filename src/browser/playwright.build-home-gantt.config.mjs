import config from './playwright.design-parity.config.mjs'

// Design comparisons stay in disposable artifacts. Unknown-value elements have
// no design counterpart, so their reviewed regression captures are durable.
export default {
  ...config,
  // Match the motion suite's capture setup; failures retain screenshots and
  // numeric diagnostics. Use --trace on for a focused reproduction.
  use: { ...config.use, trace: 'off' },
  projects: [
    { name: 'gantt', testMatch: 'build-home-gantt.browser.spec.mjs' },
    {
      name: 'gantt-unknown',
      testMatch: 'build-home-gantt-unknown.browser.spec.mjs',
      snapshotPathTemplate: '{testDir}/build-home-gantt-snapshots/{arg}{ext}'
    }
  ]
}
