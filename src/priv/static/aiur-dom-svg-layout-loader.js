(() => {
  const adapterUrl = (element) => {
    const value = element.dataset.layoutAdapterUrl

    try {
      const url = new URL(value, window.location.origin)
      if (url.origin !== window.location.origin || url.username || url.password || url.search || url.hash || url.pathname !== "/aiur-dom-svg-layout-adapter.js") return null
      return url.pathname
    } catch {
      return null
    }
  }

  const fallback = (element) => {
    element.classList.remove("is-layout-ready")
    element.classList.add("is-layout-fallback")
    element.dataset.layoutHealth = "fallback"
  }

  const createLiveViewHook = (optionsFactory = () => ({})) => ({
    mounted() {
      const context = this
      context.__domSvgLayoutDestroyed = false
      const url = adapterUrl(context.el)

      if (!url) {
        fallback(context.el)
        return
      }

      import(url)
        .then((adapter) => {
          if (context.__domSvgLayoutDestroyed) return

          context.__domSvgLayoutHook = adapter.createDomSvgLayoutHook(optionsFactory(context))
          context.__domSvgLayoutHook.mounted.call(context)
        })
        .catch(() => fallback(context.el))
    },
    beforeUpdate() {
      this.__domSvgLayoutHook?.beforeUpdate.call(this)
    },
    updated() {
      this.__domSvgLayoutHook?.updated.call(this)
    },
    destroyed() {
      this.__domSvgLayoutDestroyed = true
      this.__domSvgLayoutHook?.destroyed.call(this)
      this.__domSvgLayoutHook = null
    }
  })

  window.AiurDomSvgLayout = { createLiveViewHook }
})()
