const statuses = ['core', 'optional', 'experimental', 'planned', 'deprecated']
const kinds = ['in-app', 'package', 'repository', 'client']
const componentFields = ['id', 'name', 'summary', 'status', 'kind', 'install', 'requires', 'optional', 'capabilities', 'config', 'env', 'docs']
const featureFields = ['name', 'summary', 'extends', 'adds']

function fail(id, field) {
  throw new Error(`Component directory: ${id}: invalid or missing ${field}`)
}

function string(value, id, field) {
  if (typeof value !== 'string' || !value.trim()) fail(id, field)
}

function strings(value, id, field) {
  if (!Array.isArray(value)) fail(id, field)
  for (const entry of value) string(entry, id, field)
}

function pick(value, fields) {
  return Object.fromEntries(fields.map((field) => [field, value[field]]))
}

function byName(a, b) {
  return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
}

export function projectDirectory(manifest) {
  if (!Array.isArray(manifest?.components) || !manifest.components.length || !Array.isArray(manifest.features)) {
    fail('manifest', 'components or features')
  }
  const components = manifest.components.map((component) => {
    const id = component?.id ?? 'unknown component'
    for (const field of ['id', 'name', 'summary']) string(component?.[field], id, field)
    if (!statuses.includes(component.status)) fail(id, 'status')
    if (!kinds.includes(component.kind)) fail(id, 'kind')
    for (const field of ['requires', 'optional', 'capabilities', 'config', 'env', 'docs']) strings(component[field], id, field)
    const install = component.install
    if (!['included', 'npm', 'setup'].includes(install?.type)) fail(id, 'install')
    const installFields = { included: ['type'], npm: ['type', 'package'], setup: ['type', 'docs'] }[install.type]
    for (const field of installFields) string(install[field], id, `install.${field}`)
    return { ...pick(component, componentFields), install: pick(install, installFields) }
  }).filter((component) => component.status !== 'planned')
    .sort((a, b) => statuses.indexOf(a.status) - statuses.indexOf(b.status) || byName(a, b))

  const planned = manifest.features.filter((feature) => feature.public === true && feature.shipped_in == null)
    .map((feature) => {
      const id = feature.id ?? 'unknown feature'
      for (const field of ['name', 'summary']) string(feature[field], id, field)
      for (const field of ['extends', 'adds']) strings(feature[field], id, field)
      return pick(feature, featureFields)
    }).sort(byName)
  return { components, planned }
}
