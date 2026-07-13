import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Aiur Docs',
  description: 'Run and coordinate fleets of coding agents with Aiur.',
  base: '/docs/',
  outDir: '../dist/docs',
  cleanUrls: true,
  ignoreDeadLinks: [/\.claude\//, /\.codex\//, /src\/lib\//],
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
    siteTitle: 'aiur · cli',
    nav: [
      { text: 'Home', link: 'https://aiur.team/' },
      { text: 'Docs', link: '/guide/quick-start', activeMatch: '^/' }
    ],
    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Skills', link: '/skills' },
          { text: 'Quick start', link: '/guide/quick-start' },
          { text: 'Configuration', link: '/reference/configuration' }
        ]
      },
      {
        text: 'Concepts',
        items: [
          { text: 'What Aiur is', link: '/concepts/what-is-aiur' },
          { text: 'How a ticket flows', link: '/concepts/ticket-lifecycle' },
          { text: 'Operating Aiur', link: '/concepts/operating-aiur' }
        ]
      }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/its-everdred/aiur' }
    ],
    footer: {
      message: 'Command macro, delegate micro, maximize APM.',
      copyright: 'Aiur · AI Unit Runtime for Executors'
    },
    outline: { level: [2, 3], label: 'On this page' },
    search: { provider: 'local' }
  }
})
