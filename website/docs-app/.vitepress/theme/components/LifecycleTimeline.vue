<script setup lang="ts">
import { computed } from 'vue'
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
</script>

<template>
  <figure class="lifecycle" aria-label="Ticket lifecycle timeline">
    <div class="horizontal-layout" aria-label="Horizontal timeline">
      <div class="actor-legend"><span class="actor-executor">Executor</span><span class="actor-ci">CI</span><span class="actor-aiur-agent">Aiur agent</span><span class="actor-aiur-daemon">Aiur daemon</span></div>
      <div class="horizontal-chart">
        <div class="phase-rail" aria-label="Lifecycle phases">
          <div v-for="([name, start, end]) in phases" :key="name" class="phase" :style="phaseStyle(start, end)"><span>{{ name === 'Dispatch' ? 'Dis' : name }}<wbr v-if="name === 'Dispatch'">{{ name === 'Dispatch' ? 'patch' : '' }}</span></div>
        </div>
        <div class="progress-rail" aria-label="Illustrative progress percentage positions">
          <span v-for="marker in progress" :key="marker.percent" class="progress-marker" :style="{ left: `${marker.at * 100}%` }">{{ marker.percent }}%</span>
        </div>
      </div>
    </div>

    <ol class="vertical-layout" aria-label="Vertical timeline in time order">
      <li v-for="moment in moments" :key="moment.at" class="timeline-point">
        <div class="rail-labels">
          <span v-for="name in moment.phaseLabels" :key="name" class="phase-label">{{ name }}</span>
          <span v-for="percent in moment.percentages" :key="percent" class="percent-label">{{ percent }}%</span>
          <span class="rail-dot" aria-hidden="true"></span>
          <span class="time-label">{{ Math.round(moment.at * 100) }}%</span>
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
.lifecycle { container: lifecycle / inline-size; margin: 1.5rem 0; max-width: 100%; color: var(--vp-c-text-1); }
@media (min-width: 1400px) {
  .lifecycle { width: min(calc(100vw - 600px), 2200px); max-width: 2200px; margin-left: calc((100% - min(calc(100vw - 600px), 2200px)) / 2 + 220px); }
}
.horizontal-layout { display: none; margin-bottom: 18px; }
.vertical-layout { list-style: none; padding: 0; margin: 0; }
.timeline-point { display: grid; grid-template-columns: 94px minmax(0, 1fr); gap: 12px; min-width: 0; }
.rail-labels { position: relative; display: flex; flex-direction: column; align-items: flex-end; gap: 5px; padding: 8px 22px 18px 0; border-right: 2px solid var(--vp-c-divider); text-align: right; }
.rail-dot { position: absolute; top: 12px; right: -7px; width: 12px; height: 12px; border: 2px solid var(--vp-c-brand-1); border-radius: 50%; background: var(--vp-c-bg); }
.phase-label, .percent-label, .time-label { font-size: 12px; line-height: 1.35; }
.phase-label { color: var(--vp-c-text-1); font-weight: 700; }
.percent-label { color: var(--vp-c-brand-1); font-weight: 700; }
.time-label { color: var(--vp-c-text-2); font-variant-numeric: tabular-nums; }
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
@container lifecycle (min-width: 720px) {
  .horizontal-layout { display: block; }
  .actor-legend { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 8px; font-size: 12px; font-weight: 700; }
  .actor-legend span { border-left: 3px solid var(--actor-color); padding: 4px 7px; }
  .horizontal-chart { position: relative; min-width: 0; height: 72px; }
  .phase-rail { position: absolute; top: 4px; left: 0; width: 100%; height: 42px; border-block: 2px solid var(--vp-c-divider); }
  .phase { position: absolute; height: 38px; box-sizing: border-box; border-left: 1px solid var(--vp-c-divider); background: var(--vp-c-bg-soft); overflow: hidden; }
  .phase:last-child { border-right: 1px solid var(--vp-c-divider); }
  .phase span { display: block; padding: 7px 2px; font-size: 11px; line-height: 1.15; white-space: normal; overflow-wrap: anywhere; }
  .progress-rail { position: absolute; top: 46px; left: 0; width: 100%; height: 25px; border-bottom: 2px solid var(--vp-c-brand-1); }
  .progress-marker { position: absolute; top: 2px; transform: translateX(-50%); color: var(--vp-c-brand-1); font-size: 12px; font-weight: 700; }
  .progress-marker:first-child { transform: none; }
  .progress-marker:last-child { transform: translateX(-100%); }
  .progress-marker::after { content: ''; position: absolute; top: 16px; left: 50%; width: 1px; height: 9px; background: var(--vp-c-brand-1); }
}
@media (prefers-reduced-motion: reduce) {
  .lifecycle *, .lifecycle *::before, .lifecycle *::after { scroll-behavior: auto !important; animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
</style>
