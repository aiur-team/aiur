import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'

const sensitiveEnvironmentNames = ['AIUR_DASHBOARD_PASSWORD', 'AIUR_DASHBOARD_USERNAME', 'AIUR_SUPERVISOR_TOKEN', 'GITHUB_TOKEN']
const textExtensions = new Set(['.json', '.log', '.md', '.txt'])

export function syntheticFixtureEnvironment(environment = process.env) {
  return {
    AIUR_BROWSER_PORT: environment.AIUR_BROWSER_PORT ?? '',
    AIUR_BROWSER_FIXTURE_MODE: environment.AIUR_BROWSER_FIXTURE_MODE ?? 'synthetic'
  }
}

export function sanitizeDiagnostic(value, environment = process.env) {
  let sanitized = String(value)

  for (const name of sensitiveEnvironmentNames) {
    const secret = environment[name]
    if (secret) sanitized = sanitized.replaceAll(secret, '[REDACTED]')
  }

  return sanitized
    .replaceAll(/(authorization:\s*basic\s+)[^\s]+/gi, '$1[REDACTED]')
    .replaceAll(/(authorization:\s*bearer\s+)[^\s]+/gi, '$1[REDACTED]')
}

export async function writeSanitizedDiagnostic(root, filename, diagnostic, environment = process.env) {
  await mkdir(root, { recursive: true })
  const destination = path.join(root, filename)
  await writeFile(destination, sanitizeDiagnostic(diagnostic, environment))
  return destination
}

export async function sanitizeArtifactRoot(root, environment = process.env) {
  const entries = await readdir(root, { withFileTypes: true }).catch((error) => error.code === 'ENOENT' ? [] : Promise.reject(error))

  await Promise.all(entries.map(async (entry) => {
    const location = path.join(root, entry.name)

    if (entry.isDirectory()) {
      await sanitizeArtifactRoot(location, environment)
    } else if (entry.isFile() && textExtensions.has(path.extname(entry.name))) {
      const contents = await readFile(location, 'utf8')
      await writeFile(location, sanitizeDiagnostic(contents, environment))
    }
  }))

  return root
}

export async function artifactFiles(root) {
  const entries = await readdir(root, { withFileTypes: true }).catch((error) => error.code === 'ENOENT' ? [] : Promise.reject(error))
  const files = []

  for (const entry of entries) {
    const location = path.join(root, entry.name)

    if (entry.isDirectory()) {
      files.push(...await artifactFiles(location))
    } else if ((await stat(location)).isFile()) {
      files.push(location)
    }
  }

  return files
}
