import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import { createServer } from 'vite'
import { renderToString } from 'vue/server-renderer'
import { createSSRApp } from 'vue'
import vue from '@vitejs/plugin-vue'
import { projectDirectory } from '../reference/components-projection.mjs'

let server, Directory
before(async () => {
  server = await createServer({ configFile: false, plugins: [vue()], server: { middlewareMode: true },
    resolve: { alias: { vitepress: new URL('./fixtures/vitepress.mjs', import.meta.url).pathname } } })
  Directory = (await server.ssrLoadModule('/.vitepress/theme/components/ComponentDirectory.vue')).default
})
after(async () => { await server?.close() })
const component = (overrides = {}) => ({
  id: 'sample', name: 'Sample', summary: 'Sample behavior.', status: 'core', goal: 'run-agents', kind: 'in-app',
  docs: [], requires: [], optional: [], capabilities: [], config: [], env: [], install: { type: 'included' }, ...overrides
})
async function render(components, features = []) {
  return renderToString(createSSRApp(Directory, { data: { ...projectDirectory({ components, features }), generatedFrom: 'abc123' } }))
}

test('renders_missing_docs_and_empty_planned_without_placeholder_link', async () => {
  const html = await render([component()])
  assert.match(html, /id="component-sample"/)
  assert.match(html, /No planned features are listed yet\./)
  assert.doesNotMatch(html, /Sample documentation/)
  assert.match(html, /abc123/)
})

test('renders_status_notes_full_fields_and_real_links', async () => {
  const html = await render([
    component({ status: 'experimental', docs: ['guide/tui.md'], requires: ['old'], optional: ['old'], capabilities: ['voice.stt'], config: ['voice'], env: ['EXAMPLE_KEY'], install: { type: 'npm', package: '@aiur/example' } }),
    component({ id: 'old', name: 'Old', status: 'deprecated', install: { type: 'setup', docs: 'guide/quick-start.md' } })
  ])
  assert.match(html, /class="experimental badge"/)
  assert.match(html, /class="support-note"[^>]*>May change; support is limited\./)
  assert.match(html, /class="deprecated badge"/)
  assert.match(html, /class="support-note"[^>]*>Being retired; avoid new use\./)
  for (const value of ['voice.stt', 'EXAMPLE_KEY', 'npm install @aiur/example', '/docs/guide/quick-start', '/docs/reference/configuration-voice#voice', '#component-old']) assert.ok(html.includes(value), value)
})

test('planned_is_public_copy_only_and_shared_links_use_product_docs', async () => {
  const html = await render([component({ docs: ['khala/index.md', 'archon/index.md'] })], [
    { id: 'MP-E99', name: 'Future', summary: 'Future behavior.', public: true, shipped_in: null, extends: [], adds: [] }
  ])
  assert.match(html, /Shared with Khala/)
  assert.match(html, /href="\/docs\/archon\/index"/)
  assert.match(html, /class="badge planned"[^>]*>planned/)
  assert.match(html, /Future behavior\./)
  assert.doesNotMatch(html, /MP-E99/)
})
