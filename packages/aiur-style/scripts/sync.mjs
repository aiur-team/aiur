#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(__dirname, '..');
const distDir = path.join(packageRoot, 'dist');

// Parse arguments
const args = process.argv.slice(2);
if (args.length === 0) {
  console.error('Usage: sync.mjs <target-directory> [--only <subtrees>]');
  console.error('Example: sync.mjs ~/aiur-team --only css,js');
  process.exit(1);
}

const targetDirectory = args[0];
const targetAiurStyleDir = path.join(targetDirectory, 'aiur-style');

// Parse --only flag
let onlySubtrees = null;
const onlyIndex = args.indexOf('--only');
if (onlyIndex !== -1 && onlyIndex + 1 < args.length) {
  onlySubtrees = args[onlyIndex + 1].split(',').map(s => s.trim());
}

// Validate target directory
if (!fs.existsSync(targetDirectory)) {
  console.error(`Error: Target directory does not exist: ${targetDirectory}`);
  process.exit(1);
}

if (!fs.existsSync(distDir)) {
  console.error(`Error: dist/ directory not found at ${distDir}`);
  console.error('Run "npm run build" first');
  process.exit(1);
}

// Function to copy files recursively
function copyRecursive(src, dest, subtrees = null) {
  // If subtrees filter is specified, only copy matching directories
  if (subtrees !== null) {
    const srcBasename = path.basename(src);
    if (!subtrees.includes(srcBasename)) {
      return;
    }
  }

  if (!fs.existsSync(dest)) {
    fs.mkdirSync(dest, { recursive: true });
  }

  fs.readdirSync(src).forEach(file => {
    const srcPath = path.join(src, file);
    const destPath = path.join(dest, file);

    if (fs.statSync(srcPath).isDirectory()) {
      copyRecursive(srcPath, destPath, subtrees);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  });
}

// Function to delete stale files
function deleteStaleFiles(dest, src) {
  if (!fs.existsSync(dest)) {
    return;
  }

  fs.readdirSync(dest).forEach(file => {
    const destPath = path.join(dest, file);
    const srcPath = path.join(src, file);

    if (fs.statSync(destPath).isDirectory()) {
      // Recursively check subdirectories
      if (!fs.existsSync(srcPath)) {
        // Delete directory if it no longer exists in source
        fs.rmSync(destPath, { recursive: true });
      } else {
        deleteStaleFiles(destPath, srcPath);
      }
    } else {
      // Delete file if it no longer exists in source
      if (!fs.existsSync(srcPath)) {
        fs.unlinkSync(destPath);
      }
    }
  });
}

try {
  // Create target aiur-style directory if it doesn't exist
  if (!fs.existsSync(targetAiurStyleDir)) {
    fs.mkdirSync(targetAiurStyleDir, { recursive: true });
  }

  console.log(`Syncing dist/ to ${targetAiurStyleDir}${onlySubtrees ? ` (only: ${onlySubtrees.join(', ')})` : ''}...`);

  // Determine which subtrees to sync
  let subtreesToSync = onlySubtrees;
  if (subtreesToSync === null) {
    // Default: sync css, js, and init
    subtreesToSync = ['css', 'js', 'init', 'fonts', 'assets'];
  }

  // Copy only the specified subtrees
  fs.readdirSync(distDir).forEach(item => {
    const srcPath = path.join(distDir, item);
    const destPath = path.join(targetAiurStyleDir, item);

    // Only copy if it's a specified subtree or a file that matches
    if (fs.statSync(srcPath).isDirectory()) {
      if (subtreesToSync.includes(item)) {
        copyRecursive(srcPath, destPath);
      }
    } else if (subtreesToSync.includes(item.replace(/\.[^.]+$/, ''))) {
      // For files like aiur-style.css, check the stem without extension
      fs.copyFileSync(srcPath, destPath);
    } else if (subtreesToSync.some(st => item.startsWith(st))) {
      // Also copy if filename starts with a subtree name
      fs.copyFileSync(srcPath, destPath);
    }
  });

  // Delete stale files (only under the target aiur-style folder)
  deleteStaleFiles(targetAiurStyleDir, distDir);

  console.log(`✓ Sync complete to ${targetAiurStyleDir}`);
} catch (error) {
  console.error('✗ Sync failed:', error.message);
  process.exit(1);
}
