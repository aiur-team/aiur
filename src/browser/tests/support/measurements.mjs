export async function measureBrowserWork(page, { warmups = 2, repetitions = 4 } = {}) {
  return page.evaluate(async ({ warmups, repetitions }) => {
    const target = document.querySelector('#graph-content')
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

    for (let index = 0; index < warmups + repetitions; index += 1) {
      await new Promise((resolve) => requestAnimationFrame(resolve))
      const start = performance.now()
      target.style.transform = `translateX(${index % 2}px)`
      await new Promise((resolve) => requestAnimationFrame(resolve))
      const duration = performance.now() - start
      if (index >= warmups) samples.push(duration)
    }

    observer?.disconnect()
    return { warmups, samples, longTasks }
  }, { warmups, repetitions })
}

export function assertMeasurementBudget(measurement, budget) {
  if (measurement.samples.length === 0) throw new Error('measurement must contain post-warmup samples')

  for (const sample of measurement.samples) {
    if (sample > budget.maxSampleMs) {
      throw new Error(`measurement sample ${sample}ms exceeded ${budget.maxSampleMs}ms`)
    }
  }
}
