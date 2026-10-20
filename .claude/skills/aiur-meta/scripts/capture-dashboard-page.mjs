// DOM inspection kept separate from the capture runner so browser-evaluated code stays self-contained.

export async function inspectPage(page, name) {
  return page.evaluate((pageName) => {
    const text = document.body ? document.body.innerText : ''
    const visible = (element) => {
      const style = window.getComputedStyle(element)
      return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0
    }
    const tables = Array.from(document.querySelectorAll('table')).map((table) => ({
      label: table.getAttribute('aria-label') || table.querySelector('caption')?.innerText?.trim() || table.className,
      headers: Array.from(table.querySelectorAll('thead th')).map((cell) => cell.innerText.trim()),
      rows: Array.from(table.querySelectorAll('tbody tr')).map((row) => Array.from(row.querySelectorAll('td')).map((cell) => cell.innerText.trim())),
      hasBody: Boolean(table.querySelector('tbody'))
    }))
    const filterGroups = Array.from(document.querySelectorAll('.filter-row[aria-label]'))
      .filter(visible)
      .map((group) => ({
        label: group.getAttribute('aria-label') || 'Filters',
        scope: group.getAttribute('data-count-scope'),
        options: Array.from(group.querySelectorAll('button.filter-chip')).map((button) => ({
          label: button.getAttribute('data-count-label') || button.innerText.trim(),
          count: Number.parseInt(button.querySelector('.count')?.innerText.trim(), 10)
        }))
      }))
    const countSummaries = Array.from(document.querySelectorAll('.history-count'))
      .filter(visible)
      .flatMap((element) => {
        const match = element.innerText.match(/(\d+)\s+of\s+(\d+)/i)
        if (!match) return []

        const section = element.closest('section')
        const label = section?.querySelector('.recent-subtitle')?.innerText.trim() || 'Table'
        return [{ label, scope: element.getAttribute('data-count-scope'), loaded: Number(match[1]), total: Number(match[2]) }]
      })
    const staleBanners = Array.from(document.querySelectorAll('[role="status"], [role="alert"], .readonly-banner, .bo-state-card'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /\bstale\b|not fresh|frozen|out of date/i.test(value))
    const kpis = Array.from(document.querySelectorAll('.an-kpi')).map((card) => ({
      label: card.querySelector('.an-kpi-label')?.innerText.trim() || '',
      value: card.querySelector('.an-kpi-val')?.innerText.trim() || '',
      sub: card.querySelector('.an-kpi-sub')?.innerText.trim() || ''
    }))
    const emptyStates = Array.from(document.querySelectorAll('.bo-state-card, .an-empty, .units-state.empty-state:not(.filtered-empty)'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /no build orders|no run telemetry|no units have been observed|no active agents|no live units|loading units/i.test(value))
    const errorStates = Array.from(document.querySelectorAll('[role="alert"], .bo-state-card, .an-empty, .error-card, .empty-state, .readonly-banner'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /\bunavailable\b|\bstructurally invalid\b|\berror\b|\bfailed\b|could not|unable to/i.test(value))
    const primaryContentSelector = {
      units: '#units-rows .units-row',
      commands: '.decision-inbox',
      'build-orders': '.bo-catalog-table, .bo-selected-summary',
      build: '#build-root',
      analytics: '#analytics-page .an-kpis'
    }[pageName]
    const metricCells = tables.flatMap((table) => table.rows.flatMap((row, rowIndex) => row.map((value, index) => ({ value, header: table.headers[index], rowIndex }))))
    const hasNAInMetric = metricCells.some((cell) => cell.value.trim() === 'N/A' && /progress|ticket|epic|wave|member|active|complete|capacity|concurrency|cpu|cost|count|total/i.test(cell.header || ''))
    const buildRoot = pageName === 'build' ? document.querySelector('#build-root') : null
    const buildSkeletonSelector = '.bd-skel, .bd-skel-lanes'
    const buildBandSelector = '.bd-now-empty'
    const buildUnavailable = buildRoot?.querySelector('.bd-loading')?.innerText.replace(/\s+/g, ' ').trim() || ''
    const buildSkeleton = Boolean(buildRoot?.querySelector(buildSkeletonSelector))
    const buildTicketCount = buildRoot?.querySelectorAll('.bd-card[data-id], .lr[data-id]').length || 0
    const buildQueueText = buildRoot?.querySelector('#bd-sec-plan .bd-sech em, #bd-sec-plan .lh em')?.innerText || ''
    const buildQueueMatch = buildQueueText.match(/(\d[\d,]*)\s+in build-queue order\b/i)
    const buildBand = buildRoot?.querySelector(buildBandSelector)?.innerText.replace(/\s+/g, ' ').trim() || ''
    const buildHydrated = Boolean(buildRoot && (
      buildTicketCount > 0 ||
      buildRoot.querySelector('.bd-mk.empty') ||
      /Build timeline unavailable/i.test(buildUnavailable)
    ))

    return {
      title: document.title,
      text,
      chars: text.length,
      liveViewConnected: Boolean(document.querySelector('[data-phx-main], [data-phx-session]')),
      primaryContent: Boolean(primaryContentSelector && document.querySelector(primaryContentSelector)),
      tables,
      filterGroups,
      countSummaries,
      staleBanners,
      emptyStates,
      errorStates,
      kpis,
      hasNAInMetric,
      buildUnavailable,
      buildSkeleton,
      buildTicketCount,
      buildOpenTicketCount: buildQueueMatch ? Number.parseInt(buildQueueMatch[1].replaceAll(',', ''), 10) : null,
      buildBand,
      buildHydrated
    }
  }, name)
}
