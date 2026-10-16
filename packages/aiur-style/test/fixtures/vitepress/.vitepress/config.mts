import { defineConfig } from 'vitepress';

export default defineConfig({
  title: 'Aiur adapter',
  base: '/test/fixtures/vitepress/.vitepress/dist/',
  appearance: true,
  themeConfig: {
    nav: [{ text: 'Guide', link: '/guide' }],
    sidebar: [{ text: 'Guide', link: '/guide' }],
  },
});
