import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import { useData } from 'vitepress'
import { defineComponent, h, onMounted, onUnmounted } from 'vue'
import './custom.css'

const THEME_KEY = 'aiur-theme'

const Layout = defineComponent({
  setup() {
    const { isDark } = useData()
    let themeObserver: MutationObserver | undefined

    onMounted(() => {
      const savedTheme = localStorage.getItem(THEME_KEY)
      if (savedTheme === 'dark' || savedTheme === 'light') {
        isDark.value = savedTheme === 'dark'
      }

      const persistTheme = () => {
        localStorage.setItem(THEME_KEY, document.documentElement.classList.contains('dark') ? 'dark' : 'light')
      }

      persistTheme()
      themeObserver = new MutationObserver(persistTheme)
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
