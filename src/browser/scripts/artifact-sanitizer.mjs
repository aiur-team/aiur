import { inflateRaw } from 'node:zlib'
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const sensitiveEnvironmentNames = ['AIUR_DASHBOARD_PASSWORD', 'AIUR_DASHBOARD_USERNAME', 'AIUR_SUPERVISOR_TOKEN', 'GITHUB_TOKEN']
const textExtensions = new Set(['.json', '.log', '.md', '.txt'])
const retainedBinaryExtensions = new Set(['.png', '.zip'])
// Aiur agent workspaces prepend a `git` wrapper to PATH that exits 127 unless
// AIUR_REAL_GIT names the real binary. `mix` shells out to git to check the
// heroicons git dependency before it will boot, so a child that loses this
// variable cannot start the fixture server at all. It is a path to a system
// binary, not a credential, so both allowlists below forward it.
const realGitName = 'AIUR_REAL_GIT'
const inheritedRuntimeNames = [
  realGitName,
  // Names the evidence directory for a #1358 proof run so a re-run can be
  // written back into the same committed directory instead of a new timestamp.
  'AIUR_STREAMDECK_PROOF_RUN',
  'CI',
  'HEX_HOME',
  'HOME',
  'LANG',
  'LC_ALL',
  'MIX_HOME',
  'MISE_CACHE_DIR',
  'MISE_CONFIG_ROOT',
  'MISE_DATA_DIR',
  'MISE_TRUSTED_CONFIG_PATHS',
  'PATH',
  'PLAYWRIGHT_BROWSERS_PATH',
  'SSL_CERT_FILE',
  'TMPDIR'
]
const inflateRawAsync = promisify(inflateRaw)

// The provider meter row only gives an OpenAI-compatible provider a pane when
// its configured credential env resolves to a non-empty value, so the meter-row
// fixture cannot reach five panes without one. These are synthetic strings that
// never leave the fixture process and are never sent to a provider; the real
// credentials stay out of the fixture environment as before.
const syntheticProviderCredentials = {
  DEEPSEEK_API_KEY: 'fixture-deepseek-key',
  MOONSHOT_API_KEY: 'fixture-moonshot-key'
}

export function syntheticFixtureEnvironment(environment = process.env) {
  return {
    ...syntheticProviderCredentials,
    AIUR_BROWSER_PORT: environment.AIUR_BROWSER_PORT ?? '',
    AIUR_BROWSER_FIXTURE_MODE: environment.AIUR_BROWSER_FIXTURE_MODE ?? 'synthetic'
  }
}

export function browserRuntimeEnvironment(environment = process.env) {
  return Object.fromEntries(inheritedRuntimeNames.flatMap((name) => environment[name] ? [[name, environment[name]]] : []))
}

export function browserChildEnvironment(environment = process.env, overrides = {}) {
  return { ...browserRuntimeEnvironment(environment), ...syntheticFixtureEnvironment(environment), ...overrides }
}

// The fixture server is a `mise exec -- mix run` child, not a Playwright child,
// so it inherits a narrower list: no CI (which changes Mix behaviour) and no
// browser download path. It lives here rather than in start-fixture.mjs so it
// can be asserted without spawning the server that module starts on import.
const fixtureRuntimeNames = [
  realGitName,
  'HOME',
  'PATH',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'SSL_CERT_FILE',
  'HEX_HOME',
  'MIX_HOME',
  'MISE_TRUSTED_CONFIG_PATHS',
  'MISE_CACHE_DIR',
  'MISE_CONFIG_ROOT',
  'MISE_DATA_DIR'
]

export function fixtureServerEnvironment(environment = process.env) {
  const runtimeEnvironment = Object.fromEntries(
    fixtureRuntimeNames.flatMap((name) => environment[name] ? [[name, environment[name]]] : [])
  )

  return { ...runtimeEnvironment, ...syntheticFixtureEnvironment(environment) }
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
    } else if (entry.isFile()) {
      const extension = path.extname(entry.name)

      if (textExtensions.has(extension)) {
        const contents = await readFile(location, 'utf8')
        await writeFile(location, sanitizeDiagnostic(contents, environment))
      } else if (!retainedBinaryExtensions.has(extension)) {
        await rm(location, { force: true })
      }
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

export async function zipEntryContents(location) {
  const archive = await readFile(location)
  const endOfCentralDirectory = findEndOfCentralDirectory(archive)
  const entryCount = archive.readUInt16LE(endOfCentralDirectory + 10)
  let offset = archive.readUInt32LE(endOfCentralDirectory + 16)
  const entries = []

  for (let index = 0; index < entryCount; index += 1) {
    if (archive.readUInt32LE(offset) !== 0x02014b50) throw new Error(`invalid ZIP central directory in ${location}`)

    const compression = archive.readUInt16LE(offset + 10)
    const compressedSize = archive.readUInt32LE(offset + 20)
    const filenameLength = archive.readUInt16LE(offset + 28)
    const extraLength = archive.readUInt16LE(offset + 30)
    const commentLength = archive.readUInt16LE(offset + 32)
    const localHeaderOffset = archive.readUInt32LE(offset + 42)
    const name = archive.subarray(offset + 46, offset + 46 + filenameLength).toString('utf8')
    const dataOffset = localHeaderOffset + 30 + archive.readUInt16LE(localHeaderOffset + 26) + archive.readUInt16LE(localHeaderOffset + 28)
    const compressed = archive.subarray(dataOffset, dataOffset + compressedSize)

    if (archive.readUInt32LE(localHeaderOffset) !== 0x04034b50) throw new Error(`invalid ZIP local header in ${location}`)

    const contents = compression === 0 ? compressed : compression === 8 ? await inflateRawAsync(compressed) : null

    if (contents) entries.push({ name, contents })

    offset += 46 + filenameLength + extraLength + commentLength
  }

  return entries
}

function findEndOfCentralDirectory(archive) {
  const minimumOffset = Math.max(0, archive.length - 65_557)

  for (let offset = archive.length - 22; offset >= minimumOffset; offset -= 1) {
    if (archive.readUInt32LE(offset) === 0x06054b50) return offset
  }

  throw new Error('ZIP end of central directory not found')
}
