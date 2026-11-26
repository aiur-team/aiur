// One minimum combination: voice input plus its transitive required components.
export function voiceDiagram(components) {
  const byId = new Map(components.map((entry) => [entry.id, entry]))
  if (!byId.has('voice-stt')) return ''
  const selected = new Set()
  function visit(id) {
    if (selected.has(id)) return
    const entry = byId.get(id)
    if (!entry) throw new Error(`Missing required component: ${id}`)
    selected.add(id)
    entry.requires.forEach(visit)
  }
  visit('voice-stt')
  const node = (id) => `c_${id.replaceAll('-', '_')}`
  const label = (name) => name.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
  const lines = ['flowchart TB']
  for (const id of [...selected].sort()) {
    const entry = byId.get(id)
    lines.push(`${node(id)}["${label(entry.name)}"]`)
    for (const required of entry.requires) lines.push(`${node(id)} --> ${node(required)}`)
  }
  return lines.join('\n')
}
