import { readFileSync, readdirSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('../../..', import.meta.url)))
const data = readFileSync(resolve(root, 'website/docs-app/.vitepress/theme/components/lifecycle-data.ts'), 'utf8')
const source = walk(resolve(root, 'src/lib')).map((path) => readFileSync(path, 'utf8')).join('\n')
const topics = [...data.matchAll(/topic:\s*'((?:ticket\.N|system)\.[a-z][a-z0-9_.-]*)'/g)].map(([, topic]) =>
  topic.replace(/^ticket\.N\./, '').replace(/^system\./, '')
)
const unique = [...new Set(topics)]
const missing = unique.filter((topic) => !topicExists(topic))

if (!unique.length) throw new Error('No lifecycle event topics found in lifecycle data')
if (missing.length) {
  console.error(`Lifecycle topics missing from src/lib: ${missing.join(', ')}`)
  process.exit(1)
}
console.log(`Lifecycle topic guard: ${unique.length} literal topic suffixes found in src/lib`)

function topicExists(topic) {
  if (topic.startsWith('agent.phase.')) {
    const phase = topic.slice('agent.phase.'.length)
    return source.includes('"agent.phase."') && source.includes('ticket.#{id}.agent.#{name}') &&
      new RegExp(`phrase_for_phase\\("${escapeRegExp(phase)}"\\)`).test(source)
  }
  return literalSuffixExists(topic)
}

function literalSuffixExists(topic) {
  return new RegExp(`(?:^|[.\\x22'\\x60])${escapeRegExp(topic)}(?:$|[\\x22'\\x60])`, 'm').test(source)
}

function walk(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = resolve(directory, name)
    return statSync(path).isDirectory() ? walk(path) : path.endsWith('.ex') ? [path] : []
  })
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
