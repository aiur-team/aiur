import DefaultTheme from 'vitepress/theme'
import VPButton from 'vitepress/dist/client/theme-default/components/VPButton.vue'
import type { Theme } from 'vitepress'
import { defineComponent, h, onMounted, onUnmounted } from 'vue'
import './custom.css'

const Layout = defineComponent({
  setup() {
    let themeObserver: MutationObserver | undefined

    onMounted(() => {
      const persistVisibleTheme = () => {
        localStorage.setItem('aiur-theme', document.documentElement.classList.contains('dark') ? 'dark' : 'light')
      }

      persistVisibleTheme()
      themeObserver = new MutationObserver(persistVisibleTheme)
      themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
    })

    onUnmounted(() => themeObserver?.disconnect())

    return () => h(DefaultTheme.Layout!)
  }
})

export default {
  extends: DefaultTheme,
  Layout,
  // VPButton carries scoped styles, so a hand-written `.VPButton` anchor in
  // markdown would render unstyled. Register the real component instead.
  enhanceApp({ app }) {
    app.component('VPButton', VPButton)
  }
} satisfies Theme
