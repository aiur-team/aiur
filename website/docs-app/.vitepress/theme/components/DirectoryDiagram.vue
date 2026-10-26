<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { useData } from 'vitepress'
import type { PublicComponent } from '../../../reference/components.data'
import { voiceDiagram } from './directory-diagram.mjs'

const props = defineProps<{ components: PublicComponent[] }>()
const { isDark } = useData()
const svg = ref('')
const unavailable = ref(false)
let renderVersion = 0
async function render() {
  const version = ++renderVersion
  try {
    const source = voiceDiagram(props.components)
    if (!source) { unavailable.value = true; return }
    const { default: mermaid } = await import('mermaid')
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: isDark.value ? 'dark' : 'default' })
    const result = await mermaid.render(`directory-voice-${version}`, source)
    if (version === renderVersion) { svg.value = result.svg; unavailable.value = false }
  } catch {
    if (version === renderVersion) { svg.value = ''; unavailable.value = true }
  }
}
onMounted(render)
watch(isDark, render)
</script>

<template>
  <section aria-labelledby="minimum-combinations">
    <h2 id="minimum-combinations">Minimum combinations</h2>
    <p>Voice input and its required components. Arrows point to requirements; the entries above list every dependency.</p>
    <p v-if="unavailable" role="status">Diagram unavailable. Use the required dependencies listed above.</p>
    <div v-else class="directory-diagram" role="img" aria-label="Voice input and its required components" v-html="svg" />
  </section>
</template>

<style scoped>
.directory-diagram :deep(svg) { width: 100%; height: auto; }
</style>
