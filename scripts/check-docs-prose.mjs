#!/usr/bin/env node
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export async function markdownFiles(root) {
  const entries = await readdir(root, { withFileTypes: true })
  const nested = await Promise.all(entries.map(async (entry) => {
    const absolute = path.join(root, entry.name)
    if (entry.name === 'node_modules') return []
    if (entry.isDirectory()) return markdownFiles(absolute)
    return entry.isFile() && entry.name.endsWith('.md') ? [absolute] : []
  }))
  return nested.flat()
}

export function proseParagraphs(markdown) {
  return markdown
    .split(/\n\s*\n/)
    .map((block) => block.replace(/\n/g, ' ').trim())
    .filter((block) => block !== '')
    .filter((block) => !/^(#|\||```|:::|<|[-*+] |\d+\. )/.test(block))
}

export function proseBeforeTables(markdown) {
  const blocks = markdown.split(/\n\s*\n/).map((block) => block.replace(/\n/g, ' ').trim())
  return blocks.filter((block, index) => proseParagraphs(block).length === 1 && blocks[index + 1]?.startsWith('|'))
}

export function sentenceCount(paragraph) {
  return paragraph.match(/[.!?](?=\s|$)/g)?.length ?? 0
}

export async function checkDocsProse(root) {
  const failures = []
  for (const file of await markdownFiles(root)) {
    const markdown = await readFile(file, 'utf8')
    for (const paragraph of proseParagraphs(markdown)) {
      if (paragraph.length > 360) {
        failures.push(`${path.relative(root, file)}: ${paragraph.length} characters (max 360): ${paragraph}`)
      }
    }
    for (const paragraph of proseBeforeTables(markdown)) {
      if (sentenceCount(paragraph) > 1) {
        failures.push(`${path.relative(root, file)}: more than one sentence above a table: ${paragraph}`)
      }
    }
  }
  return failures
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2] ?? fileURLToPath(new URL('../website/docs-app', import.meta.url))
  const failures = await checkDocsProse(root)
  if (failures.length) {
    console.error(failures.join('\n'))
    process.exitCode = 1
  } else {
    console.log('Docs prose check passed (max 360 characters per paragraph; one sentence above tables).')
  }
}
