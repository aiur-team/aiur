#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
import { buildTokens, tokens } from '../src/tokens/build.mjs';

const cssDir = path.join(packageRoot, 'src/css');
// vitepress.css ships as its own entry point; every other source becomes dist/css/<file>.
export const componentCssFiles = () =>
  fs.readdirSync(cssDir).filter(file => file.endsWith('.css') && file !== 'vitepress.css').sort();
// Font loading is opt-in; consumers adopt fonts.css in their migration.
export const isBundled = file => file !== 'fonts.css';
// Individual CSS lives one directory deeper than the consolidated stylesheet.
export const readableCss = css => css.replaceAll("'./fonts/", "'../fonts/");

export function build(outputDir = path.join(packageRoot, 'dist')) {
  fs.mkdirSync(path.join(outputDir, 'css'), { recursive: true });
  execFileSync(path.join(packageRoot, 'node_modules/.bin/tsc'),
    ['--project', path.join(packageRoot, 'tsconfig.json'), '--outDir', path.join(outputDir, 'js')],
    { cwd: packageRoot, stdio: 'inherit' });
  const contents = componentCssFiles().map(file => {
    const css = fs.readFileSync(path.join(cssDir, file), 'utf8').replace(/\r\n/g, '\n');
    fs.writeFileSync(path.join(outputDir, 'css', file), readableCss(css));
    return isBundled(file) ? css : '';
  });
  fs.writeFileSync(path.join(outputDir, 'aiur-style.css'), buildTokens(outputDir) + contents.join('\n').replace(/\n[ \t]*}/g, ' }'));
  fs.mkdirSync(path.join(outputDir, 'init'), { recursive: true });
  fs.copyFileSync(path.join(packageRoot, 'src/init/theme-init.js'), path.join(outputDir, 'init/theme-init.js'));
  fs.copyFileSync(path.join(cssDir, 'fonts.css'), path.join(outputDir, 'fonts.css'));
  for (const directory of ['fonts', 'assets']) {
    fs.cpSync(path.join(packageRoot, directory), path.join(outputDir, directory), { recursive: true });
  }
  // VitePress uses .dark even when the host prefers light; derive its bridge from tokens.
  const darkTokens = Object.entries(tokens.dark).map(([name, value]) =>
    `    --aiur-${name.replaceAll('.', '-')}: ${value};`).join('\n');
  fs.writeFileSync(path.join(outputDir, 'vitepress.css'),
    `@layer aiur.tokens {\n  html.dark {\n    color-scheme: dark;\n${darkTokens}\n  }\n}\n` +
    fs.readFileSync(path.join(cssDir, 'vitepress.css'), 'utf8'));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  build(path.resolve(packageRoot, process.argv[2] ?? 'dist'));
  console.log('✓ Build complete');
}
