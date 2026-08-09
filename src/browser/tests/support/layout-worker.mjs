import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const manifestPath = path.resolve(browserRoot, '../priv/static/vendor/elk/0.11.1/manifest.json')

export const dashboardCredentials = {
  username: 'browser_fixture',
  password: 'browser_fixture_password'
}

export async function layoutAssetUrls() {
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))

  return {
    engine: manifest.assets.engine.url,
    worker: manifest.assets.worker.url,
    client: manifest.assets.client.url
  }
}

export function layoutRequest(count, { generation = 1, cycle = false, externalStub = false } = {}) {
  const nodes = Array.from({ length: count }, (_, index) => ({
    id: `node_${index}`,
    width: 120,
    height: 48,
    lane: index % 2,
    phase: index % 3,
    ...(externalStub && index === count - 1 ? { stub: true } : {})
  }))
  const edges = nodes.slice(1).map((node, index) => ({ id: `edge_${index}`, source: `node_${index}`, target: node.id }))

  if (cycle && count > 1) edges.push({ id: `edge_${edges.length}`, source: nodes.at(-1).id, target: nodes[0].id })

  return {
    type: 'layout',
    version: 1,
    requestId: `request_${generation}_${count}`,
    generation,
    constraints: {
      lanes: [{ index: 0 }, { index: 1 }],
      phases: [{ index: 0 }, { index: 1 }, { index: 2 }]
    },
    nodes,
    edges,
    options: { direction: 'RIGHT', edgeRouting: 'ORTHOGONAL', randomSeed: 1, thoroughness: 1 }
  }
}
