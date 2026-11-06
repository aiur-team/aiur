#!/usr/bin/env node
// Write `dist/`: the package as consumers load it.
//
// The source is plain ESM with no TypeScript to compile and no bundler, so the
// build is a copy plus the generated stylesheet. That is what lets a plain page
// import the package with no build step on the consumer's side.
import { copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { STYLES, STYLESHEET_NAME } from '../src/styles.js';
import { MODULES } from './modules.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = `${root}dist`;

const moduleNames = Object.keys(MODULES);

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

for (const name of moduleNames) await copyFile(`${root}src/${name}`, `${dist}/${name}`);
await copyFile(`${root}src/index.d.ts`, `${dist}/index.d.ts`);

const stylesheet = `/* ${STYLESHEET_NAME} - generated from src/styles.js; every value is an aiur-style token. */\n${STYLES}`;
await writeFile(`${dist}/${STYLESHEET_NAME}`, stylesheet, 'utf8');

// A consumer that imports the package from `dist` should get the source it was
// built from, so the only difference between the two is the path.
const source = await readFile(`${root}src/index.js`, 'utf8');
const built = await readFile(`${dist}/index.js`, 'utf8');
if (source !== built) throw new Error('dist/index.js does not match src/index.js');

process.stdout.write(`built ${moduleNames.length} modules and ${STYLESHEET_NAME} into dist/\n`);
