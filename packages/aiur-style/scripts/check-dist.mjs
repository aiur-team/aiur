#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { tmpdir } from 'os';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(__dirname, '..');
const distDir = path.join(packageRoot, 'dist');
const tempDir = path.join(tmpdir(), `aiur-style-check-${Date.now()}-${Math.random().toString(36).slice(2)}`);
const tempDistDir = path.join(tempDir, 'dist');

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
  execFileSync(process.execPath, [path.join(__dirname, 'build.mjs'), tempDistDir], {
    cwd: packageRoot,
    stdio: 'inherit'
  });

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
    process.exitCode = 1;
  } else {
    console.log('✓ dist/ is up to date');
  }
} catch (error) {
  console.error('✗ check-dist failed:', error.message);
  process.exitCode = 1;
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
