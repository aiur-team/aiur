import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { fileURLToPath, URL } from 'node:url'
import { products } from './products'

const [aiur, archon, khala] = products

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
    publicDir: '../public',
    resolve: {
      alias: [
        {
          // The nav-bar logo and title become the product switcher.
          find: /^.*\/VPNavBarTitle\.vue$/,
          replacement: fileURLToPath(new URL('./theme/components/ProductSwitcher.vue', import.meta.url))
        }
      ]
    }
  },
  // Each product is a locale, so it gets its own nav, page title and search
  // index. No locale sets a `label`, which keeps VitePress's language menu
  // hidden: these are products, not translations.
  locales: {
    root: {
      lang: 'en-US',
      themeConfig: {
        socialLinks: [{ icon: 'github', link: 'https://github.com/aiur-team/aiur' }]
      }
    },
    archon: {
      lang: 'en-US',
      title: 'Archon Docs',
      description: 'Always-on architecture docs: one self-contained HTML file that also works as a hosted, commentable page.',
      themeConfig: {
        siteTitle: archon.wordmark,
        nav: [
          { text: 'Home', link: 'https://archon.aiur.team/', target: '_self' },
          { text: 'Docs', link: archon.root, activeMatch: '^/archon/' }
        ],
        socialLinks: [{ icon: 'github', link: 'https://github.com/aiur-team/archon' }],
        footer: {
          message: 'A document is an argument, not a summary.',
          copyright: 'Archon · Always-on Architecture Docs'
        }
      }
    },
    khala: {
      lang: 'en-US',
      title: 'Khala Docs',
      description: 'Connect AI agents owned by different people over end-to-end encrypted chat, with human approval before delivery.',
      themeConfig: {
        siteTitle: khala.wordmark,
        // No social link: the Khala repository is private.
        nav: [{ text: 'Docs', link: khala.root, activeMatch: '^/khala/' }],
        footer: {
          message: 'Nothing reaches your agent until you approve it.',
          copyright: 'Khala · Encrypted chat between agents'
        }
      }
    }
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
    logo: aiur.logo!,
    siteTitle: aiur.wordmark,
    nav: [
      { text: 'Home', link: 'https://aiur.team/', target: '_self' },
      { text: 'Docs', link: '/guide/quick-start', activeMatch: '^/' }
    ],
    // Per-path sidebars: Archon and Khala each get their own, and every other
    // path is Aiur's.
    sidebar: {
      '/archon/': [
        {
          text: 'Introduction',
          items: [{ text: 'Quick start', link: '/archon/quick-start' }]
        },
        {
          text: 'Resources',
          items: [
            { text: 'How Archon works', link: 'https://archon.aiur.team/how-archon-works/' },
            { text: 'Instructions for agents', link: 'https://archon.aiur.team/AGENTS.md' },
            { text: 'The archon-doc skill', link: 'https://archon.aiur.team/skills/archon-doc/SKILL.md' }
          ]
        }
      ],
      '/khala/': [
        {
          text: 'Introduction',
          items: [{ text: 'Quick start', link: '/khala/quick-start' }]
        }
      ],
      '/': [
        {
          text: 'Introduction',
          items: [
            { text: 'Overview', link: '/' },
            { text: 'Quick start', link: '/guide/quick-start' }
          ]
        },
        {
          text: 'Interfaces',
          items: [
            { text: 'TUI', link: '/guide/tui' },
            { text: 'CLI', link: '/reference/cli' },
            { text: 'GUI', link: '/guide/gui' },
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
            { text: 'Configuration', link: '/reference/configuration' },
            { text: 'Optional Optimizations', link: '/reference/optional-optimizations' }
          ]
        }
      ]
    },
    footer: {
      message: 'Command macro, delegate micro, maximize APM.',
      copyright: 'Aiur · AI Unit Runtime for Executors'
    },
    outline: { level: [2, 3], label: 'On this page' },
    search: { provider: 'local' }
  }
}))
