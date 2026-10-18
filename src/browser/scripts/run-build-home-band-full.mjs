import { pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

// Separate from AIUR_PARITY_FULL: that flag expands the shared C12 sign-off suite.
// This job retains the reviewed 104 pixel cells and 32 owned band-motion cells.
export function fullBandCommands(part) {
  if (!/^[1-4]$/.test(String(part))) throw new Error('AIUR_HOME_PARITY_PART must be 1..4')
  const suites = [
    ['tests/build-home-now-band-parity.browser.spec.mjs'],
    ['tests/build-home-motion.browser.spec.mjs', '--grep', 'product interactions .*snap[.]|product inventory/grain live 1440 dark gruvbox no-preference.*(grain[.]static [.]bd-now|inventory [.]bd-now-h)']
  ]
  // One server owns a process-wide dataset selector. Keep its tests sequential;
  // the four CI partitions each start their own isolated fixture server.
  return suites.map(suite => ['scripts/run-browser-tests.mjs', ...suite,
    '--config', 'playwright.design-parity.config.mjs', '--fully-parallel', '--workers=1', '--shard=' + part + '/4'])
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  for (const command of fullBandCommands(process.env.AIUR_HOME_PARITY_PART ?? '1')) {
    const result = spawnSync(process.execPath, command, {
      stdio: 'inherit', env: { ...process.env, AIUR_PARITY_FULL: '' }
    })
    if (result.error) throw result.error
    if (result.status !== 0) process.exit(result.status ?? 1)
  }
}
