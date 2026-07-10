import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Aiur',
  description: 'Documentation for Aiur',
  base: '/docs/',
  outDir: '../dist/docs',
  cleanUrls: true,
  ignoreDeadLinks: [/\.claude\//, /\.codex\//, /src\/lib\//],
  themeConfig: {
    nav: [{ text: 'Home', link: '/' }],
    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Skills', link: '/skills' }
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
    ]
  }
})
