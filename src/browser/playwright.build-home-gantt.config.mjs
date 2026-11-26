import config from './playwright.config.mjs'

export default {
  ...config,
  // Match the motion suite's capture setup while retaining failure traces.
  use: { ...config.use, trace: 'retain-on-failure' },
  projects: [
    { name: 'gantt', testMatch: 'build-home-gantt.browser.spec.mjs' },
    {
      name: 'gantt-unknown',
      testMatch: 'build-home-gantt-unknown.browser.spec.mjs',
      snapshotPathTemplate: '{testDir}/build-home-gantt-snapshots/{arg}{ext}'
    }
  ]
}
