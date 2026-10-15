import fs from 'node:fs';
import path from 'node:path';

const definitions = JSON.parse(fs.readFileSync(new URL('./tokens.json', import.meta.url), 'utf8'));
const names = Object.keys(definitions);
const cssName = name => `--aiur-${name.replaceAll('.', '-')}`;
const reference = value => /^\{([^}]+)\}$/.exec(value)?.[1];
const valueFor = (definition, theme) => definition[theme] ??
  (typeof definition.value === 'object' ? definition.value[theme] : definition.value);

function resolve(name, theme, seen = new Set()) {
  if (!definitions[name] || seen.has(name)) throw new Error(`Invalid token reference: ${name}`);
  seen.add(name);
  const value = valueFor(definitions[name], theme);
  if (typeof value !== 'string') throw new Error(`Missing ${theme} value: ${name}`);
  const target = reference(value);
  return target ? resolve(target, theme, seen) : value;
}

export const tokens = Object.fromEntries(['light', 'dark'].map(theme =>
  [theme, Object.fromEntries(names.map(name => [name, resolve(name, theme)]))]));
const breakpoints = { shell: 960, features2: 720, features1: 440 };
const substitutions = Object.entries(definitions).filter(([, definition]) => definition.textPair);

function textPair(foreground, background) {
  const substitution = substitutions.find(([, definition]) =>
    definition.textPair.foreground === foreground && definition.textPair.background === background);
  return { foreground: substitution?.[0] ?? foreground, background, threshold: 4.5 };
}

const contrastPairs = ['fg', 'muted', 'faint', 'accent', 'accent-ink'].flatMap(foreground =>
  ['bg', 'bg-2', 'bg-app', 'surface', 'surface-2'].map(background =>
    textPair(`color.${foreground}`, `color.${background}`)));
contrastPairs.push(...['fill', 'fill-hover', 'fill-pressed'].map(background =>
  ({ foreground: 'color.on-fill', background: `color.${background}`, threshold: 4.5 })));
contrastPairs.push(...['bg', 'bg-app'].map(background =>
  ({ foreground: 'color.focus', background: `color.${background}`, threshold: 3 })));
contrastPairs.push({ foreground: 'color.on-blocking', background: 'color.blocking', threshold: 4.5 });

function declarations(theme) {
  return names.map(name => {
    const definition = definitions[name];
    const value = valueFor(definition, theme);
    const target = reference(value);
    const comment = definition.textPair ? `    /* ${definition.description} */\n` : '';
    return `${comment}    ${cssName(name)}: ${target ? `var(${cssName(target)})` : value};`;
  }).join('\n');
}

export function buildTokens(distDir) {
  fs.mkdirSync(distDir, { recursive: true });
  const light = declarations('light');
  const dark = declarations('dark');
  const css = `@layer aiur.tokens {\n  :root {\n    color-scheme: light;\n${light}\n  }\n\n  @media (prefers-color-scheme: dark) {\n    :root:not([data-theme="light"]) {\n      color-scheme: dark;\n${dark.replaceAll('\n', '\n  ')}\n    }\n  }\n\n  :root[data-theme="dark"] {\n    color-scheme: dark;\n${dark}\n  }\n}\n`;
  fs.writeFileSync(path.join(distDir, 'tokens.css'), css);
  const exports = { tokens, breakpoints, contrastPairs };
  fs.writeFileSync(path.join(distDir, 'tokens.js'), Object.entries(exports).map(([name, value]) =>
    `export const ${name} = ${JSON.stringify(value, null, 2)};`).join('\n\n') + '\n');
  fs.writeFileSync(path.join(distDir, 'tokens.d.ts'),
    `export type TokenName = ${names.map(name => JSON.stringify(name)).join(' | ')};\n` +
    'export declare const tokens: Record<"light" | "dark", Record<TokenName, string>>;\n' +
    'export declare const breakpoints: { shell: 960; features2: 720; features1: 440 };\n' +
    'export declare const contrastPairs: { foreground: TokenName; background: TokenName; threshold: number }[];\n');
  return css;
}
