import { DomSvgLayoutAdapter } from "./aiur-dom-svg-layout/lifecycle.js"

export { matchesLayoutContext, validateLayoutResult } from "./aiur-dom-svg-layout/protocol.js"

let hookInstance = 0

export function createDomSvgLayoutHook(options = {}) {
  return {
    mounted() {
      this.__domSvgLayoutAdapter?.destroy()
      this.__domSvgLayoutAdapter = new DomSvgLayoutAdapter(this.el, options, String(++hookInstance))
      this.__domSvgLayoutAdapter.mount()
    },
    beforeUpdate() {
      this.__domSvgLayoutAdapter?.beforeUpdate()
    },
    updated() {
      this.__domSvgLayoutAdapter?.updated()
    },
    destroyed() {
      this.__domSvgLayoutAdapter?.destroy()
      this.__domSvgLayoutAdapter = null
    }
  }
}
