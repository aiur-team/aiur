import fs from 'fs';
import path from 'path';
import { test, describe } from 'node:test';
import assert from 'node:assert';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { tmpdir } from 'os';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(__dirname, '..');
const distDir = path.join(packageRoot, 'dist');
const pkgJsonPath = path.join(packageRoot, 'package.json');
const pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));

describe('dist/ validation', () => {
  test('all export targets exist', () => {
    const exports = pkgJson.exports;
    for (const [exportKey, exportValue] of Object.entries(exports)) {
      let target = exportValue;
      if (typeof exportValue === 'object') {
        target = exportValue.default || exportValue.types;
      }
      const filePath = path.join(packageRoot, target);
      assert.ok(fs.existsSync(filePath), `Export target does not exist: ${target}`);
    }
  });

  test('dist/ contains no inline scripts', () => {
    const files = [];
    const walk = (dir) => {
      fs.readdirSync(dir).forEach(file => {
        const filePath = path.join(dir, file);
        if (fs.statSync(filePath).isDirectory()) {
          walk(filePath);
        } else if (filePath.endsWith('.html')) {
          files.push(filePath);
        }
      });
    };
    walk(distDir);

    files.forEach(filePath => {
      const content = fs.readFileSync(filePath, 'utf8');
      assert.ok(
        !/<script[^>]*>/.test(content),
        `HTML file contains inline script: ${filePath}`
      );
    });
  });

  test('no http:// or https:// URLs except in licenses', () => {
    const files = [];
    const walk = (dir) => {
      fs.readdirSync(dir).forEach(file => {
        const filePath = path.join(dir, file);
        if (fs.statSync(filePath).isDirectory()) {
          walk(filePath);
        } else {
          files.push(filePath);
        }
      });
    };
    walk(distDir);

    const licenseFiles = files.filter(f => f.toLowerCase().includes('license'));
    const otherFiles = files.filter(f => !licenseFiles.includes(f));

    otherFiles.forEach(filePath => {
      const content = fs.readFileSync(filePath, 'utf8');
      assert.ok(
        !/https?:\/\//.test(content),
        `File contains http:// or https:// URL: ${filePath}`
      );
    });
  });

  test('check-dist fails when dist/ is modified', () => {
    const tempDir = path.join(tmpdir(), `aiur-style-mutation-${Date.now()}`);
    try {
      // Copy package to temp directory
      execSync(`cp -r "${packageRoot}" "${tempDir}"`, { stdio: 'pipe' });

      // Modify dist/aiur-style.css
      const cssPath = path.join(tempDir, 'dist', 'aiur-style.css');
      const originalContent = fs.readFileSync(cssPath, 'utf8');
      fs.writeFileSync(cssPath, originalContent + ' ', 'utf8');

      // Run check-dist from temp directory
      try {
        execSync(`cd "${tempDir}" && npm run check-dist`, { stdio: 'pipe' });
        assert.fail('check-dist should have exited with code 1');
      } catch (error) {
        // Expected: check-dist should fail
        assert.strictEqual(error.status, 1, 'check-dist should exit with code 1 on mismatch');
      }
    } finally {
      execSync(`rm -rf "${tempDir}"`, { stdio: 'pipe' });
    }
  });

  test('check-dist passes with clean dist/', () => {
    try {
      execSync(`cd "${packageRoot}" && npm run check-dist`, { stdio: 'pipe' });
    } catch (error) {
      assert.fail(`check-dist failed on clean dist/: ${error.message}`);
    }
  });
});
