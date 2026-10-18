import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { PROBE_SPECS } from '../scripts/browser-quarantine.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const testsRoot = path.resolve(browserRoot, 'tests')
const maxAnnotations = 10

function escapeProperty(value) {
  return String(value).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A').replaceAll(':', '%3A').replaceAll(',', '%2C')
}

function escapeData(value) {
  return String(value).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')
}

export function failedSpecAnnotationLines(failures) {
  const specs = new Set()

  for (const failure of failures) {
    if (!['failed', 'timedOut'].includes(failure.status)) continue
    const file = failure.file ?? failure.location?.file
    if (typeof file !== 'string' || !path.isAbsolute(file)) continue
    const relativeToTests = path.relative(testsRoot, file)
    if (!relativeToTests || relativeToTests.startsWith('..') || path.isAbsolute(relativeToTests) || !relativeToTests.endsWith('.spec.mjs')) continue
    specs.add(path.posix.join('src/browser/tests', relativeToTests.split(path.sep).join('/')))
  }

  // The intentional-failure probes fail by design: never a quarantine candidate.
  const paths = [...specs].filter((spec) => !PROBE_SPECS.includes(spec)).sort()
  const lines = paths.slice(0, maxAnnotations).map((spec) => {
    const message = `new-failure :: BrowserSpec :: ${spec}`
    return `::error title=aiur-test-failure,file=${escapeProperty(spec)}::${escapeData(message)}`
  })

  if (paths.length > maxAnnotations) lines.push(`::error title=aiur-test-failure::truncated :: and ${paths.length - maxAnnotations} more`)
  return lines
}
