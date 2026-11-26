import { useEffect, useRef, type ComponentPropsWithoutRef } from 'react';
import { initThemeToggle } from '../js/theme.js';

export type ThemeToggleProps = ComponentPropsWithoutRef<'button'>;

export function ThemeToggle({ className = 'aiur-theme-toggle aiur-button aiur-button--icon aiur-button--sm',
  children, ...props }: ThemeToggleProps) {
  const button = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const controller = initThemeToggle(button.current!);
    return () => controller.destroy();
  }, []);
  return <button type="button" className={className} data-aiur="theme-toggle" aria-label="Dark mode"
    aria-pressed="false" {...props} ref={button}>
    {children ?? <>
      <svg className="aiur-theme-toggle__moon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" /></svg>
      <svg className="aiur-theme-toggle__sun" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4m11.4-11.4 1.4-1.4" /></svg>
    </>}
  </button>;
}
