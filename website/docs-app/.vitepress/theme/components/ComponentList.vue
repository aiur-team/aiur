<script setup lang="ts">
import { withBase } from 'vitepress'
import type { DirectoryData } from '../../../reference/components.data'

defineProps<{ data: DirectoryData }>()
</script>

<template>
  <ul>
    <li v-for="component in data.components" :key="component.id">
      <strong>{{ component.name }}</strong> ({{ component.status }}) — {{ component.summary }}
      <a v-for="doc in component.docs" :key="doc" :href="withBase('/' + doc.replace(/\.md$/, ''))">Documentation</a>
    </li>
  </ul>
  <h2>Planned</h2>
  <ul v-if="data.planned.length">
    <li v-for="feature in data.planned" :key="feature.name">
      <strong>{{ feature.name }}</strong> — {{ feature.summary }}
    </li>
  </ul>
  <p v-else>No planned features are listed yet.</p>
  <p>Manifest: <code>{{ data.generatedFrom }}</code></p>
</template>
