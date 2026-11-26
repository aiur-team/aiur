import { useEffect, useId, useRef, type ReactNode } from 'react';
import { initShellNav } from '../js/shell.js';
import { getTheme, onThemeChange, type Theme } from '../js/theme.js';

export interface NavigationItem {
  id?: string;
  href: string;
  label: string;
  icon?: ReactNode;
  content?: ReactNode;
  count?: number;
  attention?: boolean;
  current?: boolean;
  unavailable?: boolean;
}
export interface ThemePort { theme: Theme; onThemeChange: (theme: Theme) => void }
export interface AiurShellProps {
  brand?: ReactNode;
  brandHref?: string;
  navItems?: NavigationItem[];
  navigation?: NavigationItem[];
  controls?: ReactNode;
  mobileControls?: ReactNode;
  actions?: ReactNode;
  headerContent?: ReactNode;
  sidebar?: ReactNode;
  title?: string;
  className?: string;
  theme?: ThemePort;
  collapsed?: boolean;
  defaultCollapsed?: boolean;
  onCollapsedChange?: (collapsed: boolean) => void;
  mode?: 'standalone' | 'hosted-content';
  children: ReactNode;
}

function NavItems({ items }: { items: NavigationItem[] }) {
  return <>{items.map(item => {
    const Tag = item.unavailable ? 'span' : 'a';
    return <Tag key={item.id ?? item.href} className="aiur-shell__item"
      href={item.unavailable ? undefined : item.href} aria-current={item.current ? 'page' : undefined}
      aria-disabled={item.unavailable || undefined} title={item.unavailable ? 'Coming soon' : undefined}>
      {item.content ?? <>
        {item.icon != null && <span className="aiur-shell__icon" aria-hidden="true">{item.icon}</span>}
        <span className="aiur-shell__label">{item.label}</span>
        {item.count != null && <span className={`aiur-shell__count${item.attention ? ' is-attention' : ''}`} aria-hidden="true">{item.count}</span>}
        {item.unavailable && <span className="aiur-shell__state">Coming soon</span>}
      </>}
    </Tag>;
  })}</>;
}

export function AiurShell({ brand, brandHref, navItems, navigation, controls, mobileControls, actions,
  headerContent, sidebar, title, className = '', theme, collapsed, defaultCollapsed = false,
  onCollapsedChange, mode = 'standalone', children }: AiurShellProps) {
  const root = useRef<HTMLDivElement>(null);
  const navId = useId();
  const latest = useRef({ collapsed, onCollapsedChange, theme });
  latest.current = { collapsed, onCollapsedChange, theme };
  useEffect(() => {
    if (mode === 'hosted-content') return;
    const shell = root.current!;
    const dispose = initShellNav(shell, { onToggle(value) {
      latest.current.onCollapsedChange?.(value);
      if (latest.current.collapsed !== undefined) applyCollapsed(shell, latest.current.collapsed);
    } });
    if (latest.current.collapsed !== undefined) applyCollapsed(shell, latest.current.collapsed);
    return dispose;
  }, [mode]);
  useEffect(() => {
    if (mode === 'standalone' && collapsed !== undefined) applyCollapsed(root.current!, collapsed);
  }, [mode, collapsed]);
  useEffect(() => {
    if (mode !== 'hosted-content' || latest.current.theme) return;
    const sync = () => { root.current!.dataset.theme = getTheme(); };
    sync();
    return onThemeChange(sync);
  }, [mode, theme]);
  if (mode === 'hosted-content') return <div ref={root}
    className={`aiur-shell-content-root${className ? ` ${className}` : ''}`} data-theme={theme?.theme}>{children}</div>;
  const items = navItems ?? navigation ?? [];
  const tools = controls ?? actions;
  return <div ref={root} className={`aiur-shell${className ? ` ${className}` : ''}`}
    data-nav-collapsed={collapsed ?? defaultCollapsed} data-theme={theme?.theme}>
    <header className="aiur-shell__topbar">
      <div className="aiur-shell__brand">{brandHref ? <a className="aiur-shell__brand-link" href={brandHref}>{brand}</a> : brand}{headerContent}</div>
      <div className="aiur-shell__toolbar"><div className="aiur-shell__controls">{tools}</div></div>
    </header>
    <div className="aiur-shell__body">
      <aside className="aiur-shell__sidebar" aria-label="Aiur navigation">
        <nav id={navId} className="aiur-shell__nav aiur-shell__nav--sidebar" aria-label="Aiur sidebar routes"><NavItems items={items} /></nav>
        {sidebar}
        <button type="button" className="aiur-shell__tool aiur-shell__tool--icon aiur-shell__toggle"
          aria-pressed={collapsed ?? defaultCollapsed} aria-label={collapsed ?? defaultCollapsed ? 'Expand navigation' : 'Collapse navigation'} aria-controls={navId}>
          <span className="aiur-shell__toggle-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" /><path className="aiur-shell__toggle-fill" d="M3 4h6v16H3z" fill="currentColor" stroke="none" /></svg></span>
        </button>
      </aside>
      <main className="aiur-shell__main" aria-label={title}>{children}</main>
    </div>
    <nav className="aiur-shell__nav aiur-shell__nav--pill" aria-label="Aiur mobile routes">
      <NavItems items={items} />
      {(mobileControls ?? tools) != null && <div className="aiur-shell__nav-controls">{mobileControls ?? tools}</div>}
    </nav>
  </div>;
}

function applyCollapsed(shell: HTMLElement, collapsed: boolean) {
  shell.dataset.navCollapsed = String(collapsed);
  const toggle = shell.querySelector<HTMLButtonElement>('.aiur-shell__toggle')!;
  toggle.setAttribute('aria-pressed', String(collapsed));
  toggle.setAttribute('aria-label', collapsed ? 'Expand navigation' : 'Collapse navigation');
  toggle.title = collapsed ? 'Expand navigation' : 'Collapse navigation';
}
