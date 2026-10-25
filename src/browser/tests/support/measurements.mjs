export async function nextPaint(page) {
  await page.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  }))
}

export async function measureBrowserWork(page, { operation, targetSelector = '#graph-content', warmups = 2, repetitions = 4 } = {}) {
  if (!operation) throw new Error('measurement requires an injected browser-side operation name')

  const measurement = await page.evaluate(async ({ operation, targetSelector, warmups, repetitions }) => {
    const target = document.querySelector(targetSelector)

    if (!target) throw new Error(`measurement target not found: ${targetSelector}`)

    const run = window.__aiurBrowserHarnessOperations?.[operation]

    if (typeof run !== 'function') throw new Error(`browser-side measurement operation not found: ${operation}`)

    const observedLongTasks = []
    const observer = typeof PerformanceObserver === 'undefined' ? null : new PerformanceObserver((entries) => {
      observedLongTasks.push(...entries.getEntries().map(({ startTime, duration }) => ({ startTime, duration })))
    })

    try {
      // Do not replay navigation or hydration work into this measurement.
      observer?.observe({ type: 'longtask', buffered: false })
    } catch {
      // Some browser builds omit long-task support; samples remain useful.
    }

    const samples = []
    const measuredWindows = []

    const nextPaint = () => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now())))
    })

    for (let index = 0; index < warmups + repetitions; index += 1) {
      let mutationCount = 0
      const observer = new MutationObserver((entries) => { mutationCount += entries.length })

      observer.observe(target, { attributes: true, childList: true, characterData: true, subtree: true })
      const start = performance.now()
      await run(index)
      const operationCompleted = performance.now()
      const renderedAt = await nextPaint()

      if (index >= warmups) measuredWindows.push({ start, end: renderedAt })

      mutationCount += observer.takeRecords().length
      observer.disconnect()

      if (index >= warmups) {
        samples.push({
          layoutLatencyMs: renderedAt - start,
          mainThreadMs: operationCompleted - start,
          renderMutations: mutationCount,
          coalescedUpdates: Math.max(0, mutationCount - 1),
          longTasks: []
        })
      }
    }

    observedLongTasks.push(...(observer?.takeRecords().map(({ startTime, duration }) => ({ startTime, duration })) ?? []))
    observer?.disconnect()

    for (let index = 0; index < samples.length; index += 1) {
      samples[index].window = measuredWindows[index]
    }

    return { warmups, samples, observedLongTasks }
  }, { operation, targetSelector, warmups, repetitions })

  const longTasksBySample = longTasksInWindows(
    measurement.observedLongTasks,
    measurement.samples.map(sample => sample.window)
  )

  for (const [index, sample] of measurement.samples.entries()) {
    sample.longTasks = longTasksBySample[index]
    delete sample.window
  }

  measurement.longTasks = measurement.samples.flatMap(sample => sample.longTasks)
  delete measurement.observedLongTasks
  return measurement
}

export function longTasksInWindows(entries, windows) {
  const tasksByWindow = windows.map(() => [])

  for (const entry of entries) {
    const taskEnd = entry.startTime + entry.duration
    let bestIndex = -1
    let bestOverlap = 0

    for (const [index, window] of windows.entries()) {
      const overlap = Math.max(0, Math.min(taskEnd, window.end) - Math.max(entry.startTime, window.start))
      if (overlap > bestOverlap) {
        bestIndex = index
        bestOverlap = overlap
      }
    }

    if (bestIndex >= 0) tasksByWindow[bestIndex].push(entry.duration)
  }

  return tasksByWindow
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

  }

  if (budget.longTaskPercentile !== undefined) {
    const percentile = budget.longTaskPercentile
    if (percentile <= 0 || percentile > 100) throw new Error('long-task percentile must be in (0, 100]')
    const perSampleMaximums = measurement.samples.map(sample => Math.max(0, ...(sample.longTasks ?? [])))
    const rank = Math.ceil(percentile / 100 * perSampleMaximums.length) - 1
    const value = perSampleMaximums.sort((left, right) => left - right)[rank]
    assertMaximum(`p${percentile} long task`, value, budget.maxLongTaskMs)
  } else {
    for (const sample of measurement.samples) {
      for (const longTask of sample.longTasks ?? []) assertMaximum('long task', longTask, budget.maxLongTaskMs)
    }

    for (const longTask of measurement.longTasks ?? []) assertMaximum('long task', longTask, budget.maxLongTaskMs)
  }
}

function assertMaximum(label, value, maximum) {
  if (maximum !== undefined && value > maximum) throw new Error(`${label} ${value}ms exceeded ${maximum}ms`)
}
