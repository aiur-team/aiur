import config from './playwright.design-parity.config.mjs'

export default {
  ...config,
  use: {
    ...config.use,
    launchOptions: {
      ...config.use?.launchOptions,
      args: [...(config.use?.launchOptions?.args ?? []), '--hide-scrollbars', '--enable-features=OverlayScrollbar']
    }
  }
}
