#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { tmpdir } from 'os';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(__dirname, '..');
const distDir = path.join(packageRoot, 'dist');
const tempDir = path.join(tmpdir(), `aiur-style-check-${Date.now()}-${Math.random().toString(36).slice(2)}`);
const tempDistDir = path.join(tempDir, 'dist');

// Helper: Build files into a directory
function buildToDir(outputDir) {
  // Create dist dir
  fs.mkdirSync(outputDir, { recursive: true });
  fs.mkdirSync(path.join(outputDir, 'css'), { recursive: true });
  fs.mkdirSync(path.join(outputDir, 'js'), { recursive: true });

  // Run TypeScript compiler
  execSync(`tsc --project ${path.join(packageRoot, 'tsconfig.json')} --outDir ${path.join(outputDir, 'js')}`, {
    cwd: packageRoot,
    stdio: 'pipe'
  });

  // Build CSS
  const srcCssDir = path.join(packageRoot, 'src', 'css');
  const cssFiles = fs.readdirSync(srcCssDir)
    .filter(f => f.endsWith('.css'))
    .sort();

  const cssContent = cssFiles
    .map(file => {
      const content = fs.readFileSync(path.join(srcCssDir, file), 'utf8');
      return content.replace(/\r\n/g, '\n');
    })
    .join('\n');

  fs.writeFileSync(path.join(outputDir, 'aiur-style.css'), cssContent, { encoding: 'utf8' });

  cssFiles.forEach(file => {
    const srcPath = path.join(srcCssDir, file);
    const destPath = path.join(outputDir, 'css', file);
    const content = fs.readFileSync(srcPath, 'utf8').replace(/\r\n/g, '\n');
    fs.writeFileSync(destPath, content, { encoding: 'utf8' });
  });
}

// Helper: Get all files from directory
function getAllFiles(dir) {
  const files = [];
  const walk = (currentPath) => {
    fs.readdirSync(currentPath).forEach(file => {
      const fullPath = path.join(currentPath, file);
      const relativePath = path.relative(dir, fullPath);
      if (fs.statSync(fullPath).isDirectory()) {
        walk(fullPath);
      } else {
        files.push(relativePath);
      }
    });
  };
  walk(dir);
  return files.sort();
}

try {
  // Create temp directory
  fs.mkdirSync(tempDir, { recursive: true });

  // Build into temp directory
  console.log('Building into temporary directory...');
  buildToDir(tempDistDir);

  // Compare files
  console.log('Comparing dist/ with build output...');
  const diffs = [];

  const actualFiles = getAllFiles(distDir);
  const tempFiles = getAllFiles(tempDistDir);

  // Check for missing or extra files
  const actualSet = new Set(actualFiles);
  const tempSet = new Set(tempFiles);

  tempFiles.forEach(file => {
    if (!actualSet.has(file)) {
      diffs.push(`Missing in dist/: ${file}`);
    } else {
      // Compare file contents
      const actualContent = fs.readFileSync(path.join(distDir, file), 'utf8');
      const tempContent = fs.readFileSync(path.join(tempDistDir, file), 'utf8');
      if (actualContent !== tempContent) {
        diffs.push(`Mismatch: ${file}`);
      }
    }
  });

  actualFiles.forEach(file => {
    if (!tempSet.has(file)) {
      diffs.push(`Extra in dist/: ${file}`);
    }
  });

  // Report results
  if (diffs.length > 0) {
    console.error('✗ dist/ is out of date:');
    diffs.forEach(diff => console.error(`  ${diff}`));
    process.exit(1);
  } else {
    console.log('✓ dist/ is up to date');
    process.exit(0);
  }
} catch (error) {
  console.error('✗ check-dist failed:', error.message);
  process.exit(1);
} finally {
  // Clean up temp directory
  try {
    execSync(`rm -rf "${tempDir}"`);
  } catch (e) {
    // Ignore cleanup errors
  }
}
