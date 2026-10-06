#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(__dirname, '..');
const distDir = path.resolve(packageRoot, process.argv[2] ?? 'dist');
const srcCssDir = path.join(packageRoot, 'src', 'css');
const distCssDir = path.join(distDir, 'css');

// Ensure dist directory exists
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir, { recursive: true });
}

if (!fs.existsSync(distCssDir)) {
  fs.mkdirSync(distCssDir, { recursive: true });
}

// Run TypeScript compiler
console.log('Building TypeScript...');
try {
  execFileSync(path.join(packageRoot, 'node_modules', '.bin', 'tsc'), ['--project', path.join(packageRoot, 'tsconfig.json'), '--outDir', path.join(distDir, 'js')], {
    cwd: packageRoot,
    stdio: 'inherit'
  });
  console.log('✓ TypeScript compiled');
} catch (error) {
  console.error('✗ TypeScript compilation failed');
  process.exit(1);
}

// Concatenate CSS files in sorted order
console.log('Building CSS...');
try {
  const cssFiles = fs.readdirSync(srcCssDir)
    .filter(f => f.endsWith('.css'))
    .sort();

  if (cssFiles.length === 0) {
    console.warn('⚠ No CSS files found in src/css/');
  }

  // Concatenate all CSS into main file with LF line endings
  const cssContent = cssFiles
    .map(file => {
      const content = fs.readFileSync(path.join(srcCssDir, file), 'utf8');
      return content.replace(/\r\n/g, '\n');
    })
    .join('\n');

  const mainCssPath = path.join(distDir, 'aiur-style.css');
  fs.writeFileSync(mainCssPath, cssContent, { encoding: 'utf8' });
  console.log(`✓ CSS concatenated to dist/aiur-style.css (${cssFiles.length} files)`);

  // Copy individual CSS files to dist/css/
  cssFiles.forEach(file => {
    const srcPath = path.join(srcCssDir, file);
    const destPath = path.join(distCssDir, file);
    const content = fs.readFileSync(srcPath, 'utf8').replace(/\r\n/g, '\n');
    fs.writeFileSync(destPath, content, { encoding: 'utf8' });
  });
  console.log(`✓ CSS files copied to dist/css/`);
} catch (error) {
  console.error('✗ CSS build failed:', error.message);
  process.exit(1);
}

console.log('✓ Build complete');
