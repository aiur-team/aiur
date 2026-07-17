export async function nextPaint(page) {
  await page.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  }))
}

export async function measureBrowserWork(page, { operation, targetSelector = '#graph-content', warmups = 2, repetitions = 4 } = {}) {
  if (!operation) throw new Error('measurement requires an injected browser-side operation name')

  return page.evaluate(async ({ operation, targetSelector, warmups, repetitions }) => {
    const target = document.querySelector(targetSelector)

    if (!target) throw new Error(`measurement target not found: ${targetSelector}`)

    const run = window.__aiurBrowserHarnessOperations?.[operation]

    if (typeof run !== 'function') throw new Error(`browser-side measurement operation not found: ${operation}`)

    const longTasks = []
    const observer = typeof PerformanceObserver === 'undefined' ? null : new PerformanceObserver((entries) => {
      longTasks.push(...entries.getEntries().map((entry) => entry.duration))
    })

    try {
      observer?.observe({ type: 'longtask', buffered: true })
    } catch {
      // Some browser builds omit long-task support; samples remain useful.
    }

    const samples = []

    const nextPaint = () => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now())))
    })

    for (let index = 0; index < warmups + repetitions; index += 1) {
      let mutationCount = 0
      const observer = new MutationObserver((entries) => { mutationCount += entries.length })

      observer.observe(target, { attributes: true, childList: true, characterData: true, subtree: true })
      const longTaskStart = longTasks.length
      const start = performance.now()
      await run(index)
      const operationCompleted = performance.now()
      const renderedAt = await nextPaint()

      mutationCount += observer.takeRecords().length
      observer.disconnect()

      if (index >= warmups) {
        samples.push({
          layoutLatencyMs: renderedAt - start,
          mainThreadMs: operationCompleted - start,
          renderMutations: mutationCount,
          coalescedUpdates: Math.max(0, mutationCount - 1),
          longTasks: longTasks.slice(longTaskStart)
        })
      }
    }

    observer?.disconnect()
    return { warmups, samples, longTasks }
  }, { operation, targetSelector, warmups, repetitions })
}

export function assertMeasurementBudget(measurement, budget) {
  if (measurement.samples.length === 0) throw new Error('measurement must contain post-warmup samples')

  for (const sample of measurement.samples) {
    const layoutLatencyMs = typeof sample === 'number' ? sample : sample.layoutLatencyMs
    const mainThreadMs = typeof sample === 'number' ? sample : sample.mainThreadMs
    const coalescedUpdates = typeof sample === 'number' ? 0 : sample.coalescedUpdates

    assertMaximum('layout latency', layoutLatencyMs, budget.maxLayoutLatencyMs ?? budget.maxSampleMs)
    assertMaximum('main-thread work', mainThreadMs, budget.maxMainThreadMs)
    assertMaximum('coalesced updates', coalescedUpdates, budget.maxCoalescedUpdates)

    for (const longTask of sample.longTasks ?? []) assertMaximum('long task', longTask, budget.maxLongTaskMs)
  }

  for (const longTask of measurement.longTasks ?? []) assertMaximum('long task', longTask, budget.maxLongTaskMs)
}

function assertMaximum(label, value, maximum) {
  if (maximum !== undefined && value > maximum) throw new Error(`${label} ${value}ms exceeded ${maximum}ms`)
}
