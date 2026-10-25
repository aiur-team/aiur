import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { defineLoader } from 'vitepress'
import { projectDirectory } from './components-projection.mjs'

export interface PublicComponent {
  id: string
  name: string
  summary: string
  status: 'core' | 'optional' | 'experimental' | 'planned' | 'deprecated'
  kind: 'in-app' | 'package' | 'repository' | 'client'
  install: { type: 'included' } | { type: 'npm'; package: string } | { type: 'setup'; docs: string }
  requires: string[]
  optional: string[]
  capabilities: string[]
  config: string[]
  env: string[]
  docs: string[]
}

export interface PlannedFeature {
  name: string
  summary: string
  extends: string[]
  adds: string[]
}

export interface DirectoryData {
  components: PublicComponent[]
  planned: PlannedFeature[]
  generatedFrom: string
}

declare const data: DirectoryData
export { data }

export default defineLoader({
  watch: ['../../../components.json', '../../../components/*.json'],
  load(files): DirectoryData {
    const root = files.find((file) => file.endsWith('/components.json'))
    if (!root) throw new Error('Component directory: missing components.json')
    const hash = createHash('sha256')
    function read(file: string) {
      const contents = readFileSync(file, 'utf8')
      hash.update(contents)
      try {
        return JSON.parse(contents)
      } catch {
        throw new Error(`Component directory: invalid JSON in ${file}`)
      }
    }
    const manifest = read(root)
    if (!Array.isArray(manifest.component_files) || !manifest.component_files.length) {
      throw new Error('Component directory: missing component_files')
    }
    manifest.components = [...manifest.component_files].sort().map((file: string) => read(resolve(dirname(root), file)))
    return { ...projectDirectory(manifest), generatedFrom: hash.digest('hex').slice(0, 12) }
  }
})
