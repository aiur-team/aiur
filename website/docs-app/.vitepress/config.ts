import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

export default withMermaid(defineConfig({
  title: 'Aiur Docs',
  description: 'Run and coordinate fleets of coding agents with Aiur.',
  base: '/docs/',
  outDir: '../dist/docs',
  cleanUrls: true,
  ignoreDeadLinks: [/\.claude\//, /\.codex\//, /src\/lib\//, /src\/test\//],
  appearance: {
    initialValue: 'dark',
    storageKey: 'aiur-theme'
  },
  vite: {
    publicDir: '../public'
  },
  head: [
    [
      'script',
      {},
      `(() => {
        const savedTheme = localStorage.getItem('aiur-theme')
        if (savedTheme === 'dark' || savedTheme === 'light') {
          localStorage.setItem('vitepress-theme-appearance', savedTheme)
          document.documentElement.classList.toggle('dark', savedTheme === 'dark')
        }
      })()`
    ],
    ['link', { rel: 'icon', href: '/favicon.ico', sizes: 'any' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    [
      'link',
      {
        rel: 'stylesheet',
        href: 'https://fonts.googleapis.com/css2?family=Bungee&family=JetBrains+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap'
      }
    ]
  ],
  themeConfig: {
    logo: '/assets/aiur-logo.png',
    siteTitle: 'AIUR',
    nav: [
      { text: 'Home', link: 'https://aiur.team/', target: '_self' },
      { text: 'Docs', link: '/guide/quick-start', activeMatch: '^/' }
    ],
    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Quick start', link: '/guide/quick-start' }
        ]
      },
      {
        text: 'Usage',
        items: [
          { text: 'TUI', link: '/guide/tui' },
          { text: 'CLI', link: '/reference/cli' },
          { text: 'Dashboard', link: '/guide/executor-control-center' },
          { text: 'Stream Deck', link: '/guide/stream-deck' }
        ]
      },
      {
        text: 'Concepts',
        items: [
          { text: 'Executor', link: '/concepts/executor' },
          { text: 'Units', link: '/concepts/units' },
          { text: 'Commands', link: '/concepts/commands' },
          { text: 'Build Orders', link: '/concepts/build-orders' },
          { text: 'How a ticket flows', link: '/concepts/ticket-lifecycle' },
          { text: 'Operating Aiur', link: '/concepts/operating-aiur' },
          { text: 'Message Bus', link: '/concepts/message-bus' },
          { text: 'Skills', link: '/skills' }
        ]
      },
      {
        text: 'APIs',
        items: [
          { text: 'GitHub', link: '/apis/github' },
          { text: 'ElevenLabs', link: '/apis/elevenlabs' }
        ]
      },
      {
        text: 'Reference',
        items: [
          { text: 'Configuration', link: '/reference/configuration' }
        ]
      }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/aiur-team/aiur' }
    ],
    footer: {
      message: 'Command macro, delegate micro, maximize APM.',
      copyright: 'Aiur · AI Unit Runtime for Executors'
    },
    outline: { level: [2, 3], label: 'On this page' },
    search: { provider: 'local' }
  }
}))
