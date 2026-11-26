// Build-home performance report (MP-E8-C12-T06): one row per metric and context with its
// budget and a verdict. An unmeasured metric stays `unavailable (<reason>)` with verdict
// `unmeasured`: never 0, never pass, never the last run's value.
import { execFileSync } from 'node:child_process'
import { writeSanitizedDiagnostic } from './artifact-sanitizer.mjs'

export function gitCommit() {
  try { return execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() } catch { return 'unknown' }
}

// Every budget is an upper bound; `max` is in the row's unit.
export function verdict(value, budget) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 'unmeasured'
  if (budget?.max === undefined) return 'recorded'
  return value <= budget.max ? 'pass' : 'fail'
}

export function createReport({ commit = gitCommit(), now = () => new Date() } = {}) {
  const rows = []
  return {
    rows,
    record(id, measurement, { context = 'D', budget = null } = {}) {
      const unavailable = measurement.unavailable
      const value = unavailable === undefined ? measurement.value : null
      rows.push({
        id, context, value, unit: measurement.unit ?? budget?.unit ?? null,
        budget: budget?.max ?? null, verdict: unavailable === undefined ? verdict(value, budget) : 'unmeasured',
        unavailable: unavailable ?? null, observed_at: now().toISOString(), commit
      })
    },
    markdown() {
      const cell = row => row.unavailable !== null ? `unavailable (${row.unavailable})` : `${round(row.value)}`
      const lines = ['| ID | Context | Value | Unit | Budget | Verdict | Observed at | Commit |', '| --- | --- | --- | --- | --- | --- | --- | --- |']
      for (const row of rows) lines.push(`| ${row.id} | ${row.context} | ${cell(row)} | ${row.unit ?? ''} | ${row.budget ?? 'record'} | ${row.verdict} | ${row.observed_at} | ${row.commit} |`)
      return lines.join('\n') + '\n'
    },
    async write(dir) {
      const json = await writeSanitizedDiagnostic(dir, 'build-home-perf.json', JSON.stringify(rows, null, 2) + '\n')
      const md = await writeSanitizedDiagnostic(dir, 'build-home-perf.md', this.markdown())
      process.stdout.write(`build-home perf report: ${json}\nbuild-home perf report: ${md}\n`)
      return { json, md }
    }
  }
}

const round = value => Math.round(value * 100) / 100
