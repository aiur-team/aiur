import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'

// The authored worker is kept as ordered parts (NN-name.js) and shipped as one file: a single
// worker URL and no runtime import keep the CSP and content-addressed asset unchanged.
export async function readWorkerSource(layoutSourceRoot) {
  const partsRoot = path.join(layoutSourceRoot, 'worker')
  const parts = (await readdir(partsRoot)).filter((file) => /^\d\d-.+\.js$/.test(file)).sort()

  if (parts.length === 0) throw new Error(`no layout worker parts found in ${partsRoot}`)
  return Buffer.concat(await Promise.all(parts.map((part) => readFile(path.join(partsRoot, part)))))
}
