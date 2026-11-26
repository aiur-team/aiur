import config from './playwright.config.mjs'

export default {
  ...config,
  fullyParallel: true,
  workers: 2
}
