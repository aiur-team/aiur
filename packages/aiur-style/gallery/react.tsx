import { createRoot } from 'react-dom/client';
import { AiurShell, PageFrame, ThemeToggle, type NavigationItem } from '../src/react/index.js';
import { setTheme } from '../src/js/theme.js';

// Fixture content comes from the vanilla gallery; React owns all shell/page markup and behavior.
const query = new URLSearchParams(location.search);
setTheme(query.get('theme') === 'dark' ? 'dark' : 'light');
const html = await (await fetch('../markup/shell.html')).text();
const fixture = new DOMParser().parseFromString(html, 'text/html');
const raw = (element: Element | null) => element && <span dangerouslySetInnerHTML={{ __html: element.innerHTML }} />;
const icon = (element: Element | null) => element && <svg {...Object.fromEntries(Array.from(element.attributes, a => [a.name, a.value]))}
  dangerouslySetInnerHTML={{ __html: element.innerHTML }} />;
const navItems: NavigationItem[] = Array.from(fixture.querySelectorAll('.aiur-shell__nav--sidebar .aiur-shell__item'), item => ({
  href: item.getAttribute('href') ?? '',
  label: item.querySelector('.aiur-shell__label')!.textContent!,
  icon: icon(item.querySelector('svg')),
  count: item.querySelector('.aiur-shell__count') ? Number(item.querySelector('.aiur-shell__count')!.textContent) : undefined,
  attention: !!item.querySelector('.is-attention'),
  current: item.hasAttribute('aria-current'),
  unavailable: item.hasAttribute('aria-disabled'),
}));
const pause = <button className="aiur-shell__tool aiur-shell__tool--icon aiur-shell__pause" type="button"
  aria-label="Pause all agents" aria-pressed="false" disabled>{raw(fixture.querySelector('.aiur-shell__pause'))}</button>;
createRoot(document.getElementById('root')!).render(
  <AiurShell navItems={navItems}
    brand={<><img className="aiur-shell__logo" src="assets/shell-logo.png" alt="Aiur" /><span className="aiur-shell__wordmark"><b>aiur</b></span></>}
    controls={<>{pause}<ThemeToggle className="aiur-shell__tool aiur-shell__tool--icon" aria-label="Toggle color theme">
      {raw(fixture.querySelector('[aria-label="Toggle color theme"]'))}
    </ThemeToggle></>}
    mobileControls={pause}>
    <PageFrame title="Units" icon={icon(fixture.querySelector('.aiur-page__icon svg'))}
      banner="Three units running. Two commands need your attention.">
      <p>Follow your units and commands from one place.</p>
    </PageFrame>
  </AiurShell>,
);
