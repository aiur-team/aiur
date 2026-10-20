import { createElement, type ComponentPropsWithoutRef, type ElementType } from 'react';

export type ButtonProps<T extends ElementType = 'button'> = {
  as?: T;
  variant?: 'primary' | 'ghost' | 'danger' | 'tool';
  size?: 'sm' | 'md' | 'lg';
  shape?: 'pill' | 'rounded' | 'icon';
} & Omit<ComponentPropsWithoutRef<T>, 'as' | 'size'>;

export function Button<T extends ElementType = 'button'>({
  as, variant = 'primary', size = 'md', shape = 'pill', className, ...props
}: ButtonProps<T>) {
  const tag = as ?? 'button';
  const classes = ['aiur-button', variant !== 'primary' && `aiur-button--${variant}`,
    size !== 'md' && `aiur-button--${size}`, shape !== 'pill' && `aiur-button--${shape}`, className]
    .filter(Boolean).join(' ');
  return createElement(tag, { ...(tag === 'button' ? { type: 'button' } : {}), ...props, className: classes });
}
