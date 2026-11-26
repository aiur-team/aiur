<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { items, phases, progress, type LifecycleActor, type LifecycleItem } from './lifecycle-data'

const ordered = [...items].sort((a, b) => a.at - b.at)
const moments = computed(() => {
  const points = new Map<number, { at: number; events: LifecycleItem[]; phaseLabels: string[]; percentages: number[] }>()
  const point = (at: number) => {
    if (!points.has(at)) points.set(at, { at, events: [], phaseLabels: [], percentages: [] })
    return points.get(at)!
  }
  for (const item of ordered) point(item.at).events.push(item)
  for (const [name, start] of phases) point(start).phaseLabels.push(name)
  for (const marker of progress) point(marker.at).percentages.push(marker.percent)
  return [...points.values()].sort((a, b) => a.at - b.at)
})

const actorClass = (actor: LifecycleActor) => `actor-${actor.toLowerCase().replaceAll(' ', '-')}`
const phaseStyle = (start: number, end: number) => ({ left: `${start * 100}%`, width: `${(end - start) * 100}%` })
const phaseShortLabels: Record<string, string> = { Queued: 'Q', Dispatch: 'Dsp', Implement: 'Build', 'Merge queue': 'Queue' }
const laneY: Record<LifecycleActor, number> = { Executor: 31, CI: 75, 'Aiur agent': 232, 'Aiur daemon': 276 }
const groupedItems = new Map<string, LifecycleItem[]>()
for (const item of ordered) {
  const key = `${item.at}-${item.actor}`
  groupedItems.set(key, [...(groupedItems.get(key) ?? []), item])
}
const desktopGroups = [...groupedItems].map(([key, grouped]) => ({
  key,
  at: grouped[0]!.at,
  actor: grouped[0]!.actor,
  items: grouped,
  y: laneY[grouped[0]!.actor]
}))
const overview = ref<HTMLElement | null>(null)
const markerOffsets = ref<Record<string, number>>({})
const markerStyle = (group: typeof desktopGroups[number]) => ({
  left: `calc(96px + ${group.at * 100}% - ${group.at * 96}px + ${markerOffsets.value[group.key] ?? 0}px)`,
  top: `${group.y}px`
})
const connectorStyle = (group: typeof desktopGroups[number]) => {
  const offset = markerOffsets.value[group.key] ?? 0
  return {
    left: offset < 0 ? markerStyle(group).left : `calc(96px + ${group.at * 100}% - ${group.at * 96}px)`,
    top: `${group.y + 17}px`,
    width: `${Math.abs(offset)}px`,
    transform: offset < 0 ? 'translateX(-100%)' : undefined
  }
}
const updateMarkerOffsets = () => {
  if (!overview.value) return
  const width = overview.value.clientWidth
  const gap = 22
  const edge = 11
  const next: Record<string, number> = {}
  const actors: LifecycleActor[] = ['Executor', 'CI', 'Aiur agent', 'Aiur daemon']
  for (const actor of actors) {
    const groups = desktopGroups.filter(group => group.actor === actor)
    const desired = groups.map(group => 96 + group.at * (width - 96))
    const positions = [...desired]
    for (let index = 1; index < positions.length; index++) positions[index] = Math.max(positions[index]!, positions[index - 1]! + gap)
    positions[positions.length - 1] = Math.min(positions.at(-1)!, width - edge)
    for (let index = positions.length - 2; index >= 0; index--) positions[index] = Math.min(positions[index]!, positions[index + 1]! - gap)
    positions[0] = Math.max(positions[0]!, edge)
    for (let index = 1; index < positions.length; index++) positions[index] = Math.max(positions[index]!, positions[index - 1]! + gap)
    groups.forEach((group, index) => { next[group.key] = positions[index]! - desired[index]! })
  }
  markerOffsets.value = next
}
let resizeObserver: ResizeObserver | undefined
onMounted(() => {
  updateMarkerOffsets()
  if (overview.value) {
    resizeObserver = new ResizeObserver(updateMarkerOffsets)
    resizeObserver.observe(overview.value)
  }
})
onBeforeUnmount(() => resizeObserver?.disconnect())
const progressRows = new Map([[5, 0], [10, 1], [90, 1]])
</script>

<template>
  <figure class="lifecycle" aria-label="Ticket lifecycle timeline">
    <div class="horizontal-layout" aria-label="Horizontal timeline">
      <div ref="overview" class="desktop-overview" aria-label="Actors connected to lifecycle moments">
        <span class="lane-name lane-executor actor-executor">Executor</span><span class="lane-name lane-ci actor-ci">CI</span>
        <span class="lane-name lane-agent actor-aiur-agent">Aiur agent</span><span class="lane-name lane-daemon actor-aiur-daemon">Aiur daemon</span>
        <template v-for="group in desktopGroups" :key="group.key">
          <span class="connector" :class="actorClass(group.actor)" :style="{ left: `calc(96px + ${group.at * 100}% - ${group.at * 96}px)`, top: `${group.y < 100 ? group.y + 18 : 223}px`, height: `${group.y < 100 ? 110 - group.y : group.y - 223}px` }" aria-hidden="true"></span>
          <span v-if="markerOffsets[group.key]" class="connector-offset" :class="actorClass(group.actor)" :style="connectorStyle(group)" aria-hidden="true"></span>
          <span class="desktop-marker" :class="actorClass(group.actor)" :style="markerStyle(group)" :title="group.items.map(item => `${item.actor} · ${item.kind}: ${item.label}${item.topic ? ` (${item.topic})` : ''}`).join('\n')" aria-hidden="true">
            <span v-for="(item, index) in group.items" :key="index" class="marker-symbol" :class="[`kind-${item.kind}`]">
              <svg v-if="item.kind === 'emit' || item.kind === 'consume'" viewBox="0 0 20 14"><path d="M1 1h18v12H1zM1 2l9 6 9-6" /></svg>
              <svg v-else-if="item.kind === 'note'" viewBox="0 0 16 19"><path d="M2 1h8l4 4v13H2zM10 1v4h4" /></svg>
              <span v-else>$</span>
            </span>
          </span>
        </template>
        <div class="horizontal-chart">
          <div class="phase-rail" aria-label="Lifecycle phases">
          <div v-for="([name, start, end]) in phases" :key="name" class="phase" :style="phaseStyle(start, end)" :title="name"><span>{{ phaseShortLabels[name] ?? name }}</span></div>
          </div>
          <div class="progress-rail" aria-label="Illustrative progress percentage positions">
            <span v-for="marker in progress" :key="marker.percent" class="progress-marker" :style="{ left: `${marker.at * 100}%`, top: `${2 + (progressRows.get(marker.percent) ?? 0) * 20}px` }">{{ marker.percent }}%</span>
          </div>
        </div>
      </div>
    </div>

    <ol class="vertical-layout" aria-label="Vertical timeline in time order">
      <li v-for="moment in moments" :key="moment.at" class="timeline-point">
        <div class="rail-labels">
          <span v-for="name in moment.phaseLabels" :key="name" class="phase-label">{{ name }}</span>
          <span v-for="percent in moment.percentages" :key="percent" class="percent-label">{{ percent }}%</span>
          <span class="rail-dot" aria-hidden="true"></span>
        </div>
        <div class="point-events">
          <article v-for="(item, index) in moment.events" :key="`${item.topic ?? item.label}-${index}`" class="event-card" :class="[`kind-${item.kind}`, actorClass(item.actor)]" :data-topic="item.topic" :data-kind="item.kind" tabindex="0" :aria-label="`${item.actor}, ${item.kind}: ${item.label}${item.topic ? `, ${item.topic}` : ''}`">
            <span class="kind-icon" aria-hidden="true">
              <svg v-if="item.kind === 'emit' || item.kind === 'consume'" viewBox="0 0 20 14"><path d="M1 1h18v12H1zM1 2l9 6 9-6" /></svg>
              <svg v-else-if="item.kind === 'note'" viewBox="0 0 16 19"><path d="M2 1h8l4 4v13H2zM10 1v4h4M4 9h8M4 12h8M4 15h5" /></svg>
              <span v-else>$</span>
            </span>
            <span class="event-copy"><small>{{ item.actor }} · {{ item.kind }}</small><span>{{ item.label }}</span><code v-if="item.topic">{{ item.topic }}</code></span>
          </article>
        </div>
      </li>
    </ol>
    <figcaption>One representative ticket path. Percentages are illustrative. GitHub events can arrive through polling or webhook reconciliation; failed checks, blockers, and retries add turns.</figcaption>
  </figure>
</template>

<style scoped>
.lifecycle { container: lifecycle / inline-size; box-sizing: border-box; width: 100%; max-width: 100%; margin: 1.5rem 0; color: var(--vp-c-text-1); }
.horizontal-layout { display: none; margin-bottom: 18px; }
.vertical-layout { list-style: none; padding: 0; margin: 0; }
.timeline-point { display: grid; grid-template-columns: 94px minmax(0, 1fr); gap: 12px; min-width: 0; }
.rail-labels { position: relative; display: flex; flex-direction: column; align-items: flex-end; gap: 5px; padding: 8px 22px 18px 0; border-right: 2px solid var(--vp-c-divider); text-align: right; }
.rail-dot { position: absolute; top: 12px; right: -7px; width: 12px; height: 12px; border: 2px solid var(--vp-c-brand-1); border-radius: 50%; background: var(--vp-c-bg); }
.phase-label, .percent-label { font-size: 12px; line-height: 1.35; }
.phase-label { color: var(--vp-c-text-1); font-weight: 700; }
.percent-label { color: var(--vp-c-brand-1); font-weight: 700; }
.point-events { display: grid; gap: 6px; min-width: 0; padding: 4px 0 14px; }
.event-card { --actor-color: var(--vp-c-brand-1); display: grid; grid-template-columns: 22px minmax(0, 1fr); align-items: start; gap: 8px; box-sizing: border-box; min-width: 0; min-height: 44px; padding: 7px 9px; border: 1px solid var(--actor-color); border-radius: 8px; background: var(--vp-c-bg-soft); color: var(--vp-c-text-1); font-size: 13px; line-height: 1.4; overflow-wrap: anywhere; }
.event-card:focus-visible { outline: 3px solid var(--aiur-color-focus); outline-offset: 2px; }
.event-copy { display: grid; min-width: 0; gap: 2px; overflow-wrap: anywhere; }
.event-copy small { color: var(--actor-color); font-size: 12px; font-weight: 700; }
.event-copy code { color: var(--vp-c-text-2); font-size: 12px; white-space: normal; overflow-wrap: anywhere; word-break: break-word; }
.kind-icon { display: inline-grid; place-items: center; width: 20px; height: 20px; color: var(--actor-color); }
.kind-icon svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 1.5; }
.kind-command { border-radius: 3px; font-family: var(--vp-font-family-mono); }
.kind-command .kind-icon { border: 1px solid var(--actor-color); border-radius: 3px; font-family: var(--vp-font-family-mono); }
.kind-emit { border-radius: 999px; }
.kind-emit .kind-icon svg { fill: none; }
.kind-consume { border-style: dashed; border-radius: 999px; }
.kind-consume .kind-icon svg { fill: var(--actor-color); }
.kind-note { border-style: dashed; border-radius: 3px; font-style: italic; }
.actor-executor { --actor-color: var(--aiur-color-accent); }
.actor-ci { --actor-color: var(--aiur-color-attention-ink); }
.actor-aiur-agent { --actor-color: var(--aiur-color-good-ink); }
.actor-aiur-daemon { --actor-color: var(--aiur-color-blocking-ink); }
figcaption { margin-top: 12px; color: var(--vp-c-text-2); font-size: 12px; }
@container lifecycle (min-width: 640px) {
  .horizontal-layout { display: block; }
  .desktop-overview { position: relative; width: 100%; height: 318px; margin: 0 0 24px; }
  .lane-name { position: absolute; left: 0; z-index: 2; padding: 2px 5px; border-left: 3px solid var(--actor-color); background: var(--vp-c-bg); color: var(--actor-color); font-size: 11px; font-weight: 700; }
  .lane-executor { top: 28px; } .lane-ci { top: 72px; } .lane-agent { top: 229px; } .lane-daemon { top: 273px; }
  .horizontal-chart { position: absolute; top: 128px; left: 96px; min-width: 0; width: calc(100% - 96px); height: 72px; }
  .phase-rail { position: absolute; top: 4px; left: 0; width: 100%; height: 42px; border-block: 2px solid var(--vp-c-divider); }
  .phase { position: absolute; height: 38px; box-sizing: border-box; border-left: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); overflow: hidden; }
  .phase:last-child { border-right: 1px solid var(--vp-c-divider); }
  .phase span { display: block; padding: 7px 1px; font-size: 9px; line-height: 1.15; white-space: nowrap; text-align: center; }
  .progress-rail { position: absolute; top: 46px; left: 0; width: 100%; height: 49px; border-bottom: 2px solid var(--vp-c-brand-1); }
  .progress-marker { position: absolute; transform: translateX(-50%); color: var(--vp-c-brand-1); font-size: 12px; font-weight: 700; line-height: 1; white-space: nowrap; }
  .progress-marker:first-child { transform: none; }
  .progress-marker:last-child { transform: translateX(-100%); }
  .progress-marker::after { content: ''; position: absolute; top: 16px; left: 50%; width: 1px; height: 9px; background: var(--vp-c-brand-1); }
  .desktop-marker { position: absolute; z-index: 3; display: flex; align-items: center; justify-content: center; gap: 1px; box-sizing: border-box; width: 20px; height: 20px; margin-left: -10px; border: 2px solid var(--actor-color); border-radius: 3px; background: var(--vp-c-bg); color: var(--actor-color); font-size: 7px; line-height: 1; }
  .desktop-marker.actor-executor { --actor-color: var(--aiur-color-accent); }
  .desktop-marker.actor-ci { --actor-color: var(--aiur-color-attention-ink); }
  .desktop-marker.actor-aiur-agent { --actor-color: var(--aiur-color-good-ink); }
  .desktop-marker.actor-aiur-daemon { --actor-color: var(--aiur-color-blocking-ink); }
  .marker-symbol { display: grid; place-items: center; width: 7px; height: 12px; }
  .marker-symbol svg { width: 7px; height: 8px; fill: none; stroke: currentColor; stroke-width: 1.5; }
  .marker-symbol.kind-consume svg { fill: currentColor; }
  .marker-symbol.kind-command { font-family: var(--vp-font-family-mono); }
  .connector-offset { position: absolute; z-index: 2; height: 1px; background: var(--actor-color); opacity: .65; }
  .connector { position: absolute; z-index: 1; width: 1px; background: var(--actor-color); opacity: .65; }
  .connector.actor-executor { --actor-color: var(--aiur-color-accent); }
  .connector.actor-ci { --actor-color: var(--aiur-color-attention-ink); }
  .connector.actor-aiur-agent { --actor-color: var(--aiur-color-good-ink); }
  .connector.actor-aiur-daemon { --actor-color: var(--aiur-color-blocking-ink); }
}
@media (prefers-reduced-motion: reduce) {
  .lifecycle *, .lifecycle *::before, .lifecycle *::after { scroll-behavior: auto !important; animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
</style>
