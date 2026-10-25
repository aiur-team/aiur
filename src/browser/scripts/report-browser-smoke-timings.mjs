import { appendFileSync, existsSync, readFileSync } from 'node:fs'

const [timingPath, summaryPath] = process.argv.slice(2)
if (!timingPath || !summaryPath) throw new Error('usage: report-browser-smoke-timings.mjs <timings.jsonl> <summary.md>')

if (!existsSync(timingPath)) {
  appendFileSync(summaryPath, '\n### Browser smoke suite timings\n\nNo suite completed before the shard stopped.\n')
  process.exit(0)
}

const timings = readFileSync(timingPath, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
timings.sort((left, right) => right.durationMs - left.durationMs)
const lines = [
  '',
  '### Browser smoke suite timings',
  '',
  '| Shard | Suite | Duration (s) |',
  '| ---: | --- | ---: |',
  ...timings.map(({ shard, script, durationMs }) => `| ${shard} | ${script} | ${(durationMs / 1000).toFixed(1)} |`),
  '',
  'Slowest completed suites:',
  ...timings.slice(0, 10).map(({ shard, script, durationMs }) => `- shard ${shard}: ${script} (${(durationMs / 1000).toFixed(1)}s)`),
  ''
]
appendFileSync(summaryPath, `${lines.join('\n')}\n`)
console.log(lines.join('\n'))
