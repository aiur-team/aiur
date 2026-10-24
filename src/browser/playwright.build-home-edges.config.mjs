import config from './playwright.design-parity.config.mjs'

// S-24 odd-edge product captures are pending sign-off, but must not drift silently.
export default {
  ...config,
  expect: {
    ...config.expect,
    toHaveScreenshot: {
      ...config.expect.toHaveScreenshot,
      pathTemplate: '{testDir}/build-home-edges-snapshots/{arg}{ext}'
    }
  }
}
