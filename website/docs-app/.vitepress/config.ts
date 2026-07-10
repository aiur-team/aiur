import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Aiur',
  description: 'Documentation for Aiur',
  base: '/docs/',
  outDir: '../dist/docs',
  cleanUrls: true,
  themeConfig: {
    nav: [{ text: 'Home', link: '/' }],
    sidebar: [
      {
        text: 'Introduction',
        items: [{ text: 'Overview', link: '/' }]
      }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/its-everdred/aiur' }
    ]
  }
})
