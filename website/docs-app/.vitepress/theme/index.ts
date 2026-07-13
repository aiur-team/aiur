import DefaultTheme from 'vitepress/theme'
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
  Layout
} satisfies Theme
