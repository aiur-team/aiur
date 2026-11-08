<script setup lang="ts">
import { computed, ref } from 'vue'
import { withBase } from 'vitepress'
import type { DirectoryData, PublicComponent } from '../../../reference/components.data'
import DirectoryDiagram from './DirectoryDiagram.vue'

const props = defineProps<{ data: DirectoryData }>()
const optionalOnly = ref(false)
const headings = { 'run-agents': 'Run agents', steer: 'Steer', notify: 'Notify', voice: 'Voice', hardware: 'Hardware' }
const meanings = {
  core: 'Included in the foundation of a run.', optional: 'Use when you need it.',
  experimental: 'May change; support is limited.', deprecated: 'Being retired; avoid new use.',
  planned: 'Not available yet.'
}
const groups = computed(() => props.data.groups.map((group) => ({ ...group,
  components: group.components.filter((entry) => !optionalOnly.value || entry.status === 'optional')
})).filter((group) => group.components.length))
const names = computed(() => new Map(props.data.components.map((entry) => [entry.id, entry.name])))
const docUrl = (path: string) => withBase('/' + path.replace(/\.md(?=#|$)/, ''))
const docLabel = (path: string, name: string) => path.startsWith('khala/') ? 'Shared with Khala'
  : path.startsWith('archon/') ? 'Shared with Archon' : `${name} documentation`
const configUrl = (key: string) => {
  const page = key.startsWith('agent') ? 'configuration-agent'
    : key === 'build_order' ? 'configuration-build-order' : key === 'voice' ? 'configuration-voice' : 'configuration'
  return withBase(`/reference/${page}#${key.replaceAll(/[_ .]/g, '-')}`)
}
const installCommand = (entry: PublicComponent) => entry.install.type === 'npm' ? `npm install ${entry.install.package}` : ''
</script>

<template>
  <div class="component-directory">
    <details class="status-key">
      <summary>Status guide</summary>
      <p v-for="(meaning, status) in meanings" :key="status"><span class="badge" :class="status">{{ status }}</span> {{ meaning }}</p>
    </details>
    <label class="optional-filter"><input v-model="optionalOnly" type="checkbox"> Optional only</label>
    <nav aria-label="Component goals"><a v-for="group in groups" :key="group.goal" :href="`#goal-${group.goal}`">{{ headings[group.goal] }}</a></nav>
    <p v-if="!groups.length" role="status">No optional components are listed yet.</p>
    <section v-for="group in groups" :key="group.goal" :aria-labelledby="`goal-${group.goal}`">
      <h2 :id="`goal-${group.goal}`">{{ headings[group.goal] }}</h2>
      <article v-for="entry in group.components" :id="`component-${entry.id}`" :key="entry.id" :aria-labelledby="`name-${entry.id}`">
        <header><h3 :id="`name-${entry.id}`">{{ entry.name }}</h3><span class="badge" :class="entry.status">{{ entry.status }}</span></header>
        <p>{{ entry.summary }}</p>
        <p v-if="['experimental', 'deprecated'].includes(entry.status)" class="support-note">{{ meanings[entry.status] }}</p>
        <p v-if="entry.docs.length" class="docs-links"><a v-for="doc in entry.docs" :key="doc" :href="docUrl(doc)">{{ docLabel(doc, entry.name) }}</a></p>
        <dl>
          <dt>Requires</dt><dd><template v-if="entry.requires.length"><template v-for="id in entry.requires" :key="id"><a v-if="names.has(id)" :href="`#component-${id}`" @click="optionalOnly = false">{{ names.get(id) }}</a><span v-else>{{ id }} (planned)</span></template></template><span v-else>None</span></dd>
          <dt>Optional dependencies</dt><dd><template v-if="entry.optional.length"><template v-for="id in entry.optional" :key="id"><a v-if="names.has(id)" :href="`#component-${id}`" @click="optionalOnly = false">{{ names.get(id) }}</a><span v-else>{{ id }} (planned)</span></template></template><span v-else>None</span></dd>
          <dt>Capabilities</dt><dd><code v-for="id in entry.capabilities" :key="id">{{ id }}</code><span v-if="!entry.capabilities.length">None</span></dd>
          <dt>Config keys</dt><dd><a v-for="key in entry.config" :key="key" :href="configUrl(key)"><code>{{ key }}</code></a><span v-if="!entry.config.length">None</span></dd>
          <dt>Environment names</dt><dd><code v-for="name in entry.env" :key="name">{{ name }}</code><span v-if="!entry.env.length">None</span></dd>
          <dt>Install</dt><dd><span v-if="entry.install.type === 'included'">Included with Aiur</span><code v-else-if="entry.install.type === 'npm'">{{ installCommand(entry) }}</code><a v-else :href="docUrl(entry.install.docs)">Setup instructions</a></dd>
        </dl>
      </article>
    </section>
    <DirectoryDiagram :components="data.components" />
    <section aria-labelledby="planned">
      <h2 id="planned">Planned</h2>
      <template v-if="data.planned.length"><article v-for="entry in data.planned" :key="entry.name"><header><h3>{{ entry.name }}</h3><span class="badge planned">planned</span></header><p>{{ entry.summary }}</p></article></template>
      <p v-else>No planned features are listed yet.</p>
    </section>
    <p class="manifest">Generated from manifest <code>{{ data.generatedFrom }}</code>.</p>
  </div>
</template>

<style scoped>
.component-directory { min-width: 0; }
.status-key, article { border: 1px solid var(--aiur-line); border-radius: 12px; padding: 20px; background: var(--aiur-surface); }
summary { cursor: pointer; font-weight: 600; }
.optional-filter { display: flex; gap: 10px; align-items: center; margin: 24px 0 12px; }
input { accent-color: var(--aiur-accent); width: 18px; height: 18px; }
nav, header, .docs-links { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
nav a { font-size: 14px; }
article { margin: 16px 0; scroll-margin-top: 90px; overflow-wrap: anywhere; }
header { justify-content: space-between; }
h3 { margin: 0; font-size: 20px; }
article p { margin: 12px 0; }
.badge { display: inline-block; border: 1px solid currentColor; border-radius: 6px; padding: 1px 8px; font: 12px/1.8 var(--vp-font-family-mono); }
.core { color: var(--vp-c-brand-1); }
.optional { color: var(--vp-c-text-1); }
.experimental { color: var(--vp-c-warning-1); border-style: dashed; }
.deprecated { color: var(--vp-c-danger-1); }
.planned { color: var(--vp-c-text-2); border-style: dotted; }
dl { display: grid; grid-template-columns: 150px minmax(0, 1fr); gap: 12px 16px; font-size: 14px; }
dt { color: var(--vp-c-text-2); }
dd { margin: 0; min-width: 0; }
dd a, dd code { display: inline-block; margin-right: 10px; }
code { white-space: normal; overflow-wrap: anywhere; }
.support-note, .manifest { font-size: 13px; color: var(--vp-c-text-2); }
@media (max-width: 767px) {
  article, .status-key { padding: 16px; }
  dl { grid-template-columns: minmax(0, 1fr); gap: 4px; }
  dd { margin-bottom: 10px; }
}
</style>
