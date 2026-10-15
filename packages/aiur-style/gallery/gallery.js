import { tokens, contrastPairs } from '../dist/tokens.js';
const cssName = name => `--aiur-${name.replaceAll('.', '-')}`;
function renderSwatches() {
  const theme = document.documentElement.dataset.theme ||
    (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  document.getElementById('swatches').replaceChildren(...Object.entries(tokens[theme])
    .filter(([name]) => name.startsWith('color.')).map(([name, value]) => {
      const card = document.createElement('article');
      card.className = 'swatch';
      card.dataset.token = name;
      const color = document.createElement('div');
      color.className = 'swatch-color';
      color.style.background = `var(${cssName(name)})`;
      const info = document.createElement('div');
      info.className = 'swatch-info';
      const label = document.createElement('code');
      label.textContent = cssName(name);
      const resolved = document.createElement('code');
      resolved.className = 'swatch-value';
      resolved.textContent = value;
      const sample = document.createElement('div');
      sample.className = 'swatch-sample';
      sample.textContent = 'Readable sample text';
      const pair = contrastPairs.find(pair => pair.foreground === name);
      sample.style.color = `var(${cssName(pair?.foreground ?? 'color.fg')})`;
      sample.style.background = `var(${cssName(pair?.background ?? 'color.bg')})`;
      info.append(label, resolved, sample);
      if (name.includes('-on-')) {
        const note = document.createElement('p');
        note.className = 'swatch-note';
        note.textContent = `Text on ${pair?.background ?? 'a fill'}; preserves the fixed palette.`;
        info.append(note);
      }
      card.append(color, info);
      return card;
    }));
}
// Parse theme from URL query parameter
const params = new URLSearchParams(window.location.search);
const urlTheme = params.get('theme');
if (urlTheme === 'light' || urlTheme === 'dark') {
  document.documentElement.setAttribute('data-theme', urlTheme);
}

if (urlTheme === 'system') document.documentElement.removeAttribute('data-theme');
renderSwatches();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', renderSwatches);

// Theme toggle button
const toggleBtn = document.getElementById('theme-toggle');
const html = document.documentElement;

toggleBtn.addEventListener('click', () => {
  const currentTheme = html.getAttribute('data-theme') ||
    (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
  html.setAttribute('data-theme', newTheme);
  renderSwatches();

  // Update URL
  const newUrl = new URL(window.location);
  newUrl.searchParams.set('theme', newTheme);
  window.history.replaceState({}, '', newUrl);
});
