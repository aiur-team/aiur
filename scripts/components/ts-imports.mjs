import fs from 'node:fs';
import path from 'node:path';
import { isBuiltin, createRequire } from 'node:module';
import ts from 'typescript';

const root = fs.realpathSync(process.argv[2]);
const excluded = new Set(['node_modules', 'dist', '_build', 'deps', '.git']);
const extensions = /\.(ts|tsx|mts|cts|js|mjs)$/;

function* sources(directory) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory() && !excluded.has(entry.name)) yield* sources(file);
    else if ((entry.isFile() || entry.isSymbolicLink()) && extensions.test(entry.name)) yield file;
  }
}

function resolve(specifier, file) {
  if (isBuiltin(specifier)) return '<builtin>';
  const resolved = ts.resolveModuleName(specifier, file, {
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    resolveJsonModule: true,
    allowJs: true,
  }, ts.sys).resolvedModule?.resolvedFileName;
  if (resolved) return fs.realpathSync(resolved);
  if (specifier.startsWith('.') || path.isAbsolute(specifier)) {
    const target = path.resolve(path.dirname(file), specifier);
    return fs.existsSync(target) ? fs.realpathSync(target) : target;
  }
  const packageDirectory = path.join(root, ...path.relative(root, file).split(path.sep).slice(0, 2));
  const manifest = JSON.parse(fs.readFileSync(path.join(packageDirectory, 'package.json'), 'utf8'));
  const name = specifier.startsWith('@') ? specifier.split('/').slice(0, 2).join('/') : specifier.split('/')[0];
  const dependency = Object.assign({}, manifest.peerDependencies, manifest.devDependencies, manifest.dependencies)[name];
  if (typeof dependency === 'string' && /^(file|link):/.test(dependency)) {
    const target = path.resolve(packageDirectory, dependency.replace(/^(file|link):/, ''));
    return fs.existsSync(target) ? fs.realpathSync(target) : target;
  }
  try {
    return fs.realpathSync(createRequire(file).resolve(specifier));
  } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND' && error.code !== 'ERR_PACKAGE_PATH_NOT_EXPORTED') throw error;
    return '<npm>';
  }
}

function emit(file, argument) {
  const specifier = argument && ts.isStringLiteralLike(argument) ? argument.text : '<computed>';
  const resolved = specifier === '<computed>' ? '<computed>' : resolve(specifier, file);
  if (/[\t\r\n]/.test(specifier + resolved)) throw new Error(`Unrepresentable import in ${file}`);
  console.log(`${path.relative(root, file)}\t${specifier}\t${resolved}`);
}

function visit(file, node) {
  if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
    if (node.moduleSpecifier) emit(file, node.moduleSpecifier);
  } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
    emit(file, node.moduleReference.expression);
  } else if (ts.isImportTypeNode(node)) {
    emit(file, ts.isLiteralTypeNode(node.argument) ? node.argument.literal : node.argument);
  } else if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword
    || (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
    emit(file, node.arguments[0]);
  }
  ts.forEachChild(node, child => visit(file, child));
}

try {
  const packages = path.join(root, 'packages');
  if (fs.existsSync(packages)) {
    for (const entry of fs.readdirSync(packages, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (!entry.isDirectory()) continue;
      const directory = path.join(packages, entry.name);
      JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
      // Tests outside src are subject to the same boundary as shipped source.
      for (const file of sources(directory)) {
        visit(file, ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true));
      }
    }
  }
} catch (error) {
  console.error(`ts-imports: ${error.message}`);
  process.exitCode = 2;
}
